import json
import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Annotated, Generator

from fastapi import Depends, FastAPI, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import Boolean, DateTime, Integer, String, Text, create_engine, select, text
from sqlalchemy.engine import URL
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, sessionmaker
import boto3
from botocore.exceptions import BotoCoreError, ClientError


logger = logging.getLogger(__name__)


def _publish_metric(metric_name: str, value: float = 1) -> None:
    region = os.getenv("AWS_REGION")
    namespace = os.getenv("METRICS_NAMESPACE")
    service = os.getenv("METRICS_SERVICE", "to-do-list-api")
    if not region or not namespace:
        return
    try:
        boto3.client("cloudwatch", region_name=region).put_metric_data(
            Namespace=namespace,
            MetricData=[
                {
                    "MetricName": metric_name,
                    "Dimensions": [{"Name": "Service", "Value": service}],
                    "Value": value,
                    "Unit": "Count",
                }
            ],
        )
    except (BotoCoreError, ClientError):
        logger.exception("Could not publish CloudWatch metric %s", metric_name)


def _record_database_error() -> None:
    _publish_metric("DatabaseOperationErrors")


class Base(DeclarativeBase):
    pass


class Task(Base):
    __tablename__ = "tasks"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    completed: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc)
    )


class TaskCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    description: str | None = None

    @field_validator("title")
    @classmethod
    def title_must_not_be_blank(cls, value: str) -> str:
        title = value.strip()
        if not title:
            raise ValueError("title must not be blank")
        return title


class TaskRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    title: str
    description: str | None
    completed: bool
    created_at: datetime


class VersionResponse(BaseModel):
    version: str


class HealthResponse(BaseModel):
    status: str
    version: str
    timestamp: datetime


def get_db(request: Request) -> Generator[Session, None, None]:
    session = request.app.state.session_factory()
    try:
        yield session
    except SQLAlchemyError:
        session.rollback()
        logger.exception("Database operation failed")
        _record_database_error()
        raise
    finally:
        session.close()


DatabaseSession = Annotated[Session, Depends(get_db)]


def _database_url_from_environment() -> str | URL:
    database_url = os.getenv("DATABASE_URL")
    if database_url:
        return database_url

    secret_arn = os.getenv("DB_SECRET_ARN")
    if secret_arn:
        region = os.getenv("AWS_REGION")
        if not region:
            raise RuntimeError("AWS_REGION is required when DB_SECRET_ARN is set")
        secret_response = boto3.client(
            "secretsmanager", region_name=region
        ).get_secret_value(SecretId=secret_arn)
        credentials = json.loads(secret_response["SecretString"])
        host = os.getenv("DB_HOST") or credentials.get("host")
        if not host:
            raise RuntimeError(
                "DB_HOST must be set or included in the database secret"
            )
        return URL.create(
            "postgresql+psycopg2",
            username=credentials["username"],
            password=credentials["password"],
            host=host,
            port=int(os.getenv("DB_PORT", str(credentials.get("port", 5432)))),
            database=os.getenv("DB_NAME", credentials.get("dbname", "postgres")),
        )

    host = os.getenv("DB_HOST")
    if not host:
        return "sqlite:///./tasks.db"

    required_variables = ("DB_NAME", "DB_USER", "DB_PASSWORD")
    missing_variables = [name for name in required_variables if not os.getenv(name)]
    if missing_variables:
        raise RuntimeError(
            "Missing database environment variables: " + ", ".join(missing_variables)
        )

    return URL.create(
        "postgresql+psycopg2",
        username=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        host=host,
        port=int(os.getenv("DB_PORT", "5432")),
        database=os.environ["DB_NAME"],
    )


def create_app(
    database_url: str | URL | None = None, version: str | None = None
) -> FastAPI:
    resolved_database_url = database_url or _database_url_from_environment()
    resolved_version = version or os.getenv("APP_VERSION", "dev")
    engine_options: dict[str, object] = {"pool_pre_ping": True}

    database_url_text = str(resolved_database_url)
    if database_url_text.startswith("sqlite"):
        engine_options["connect_args"] = {"check_same_thread": False}
        if database_url_text in ("sqlite://", "sqlite:///:memory:"):
            from sqlalchemy.pool import StaticPool

            engine_options["poolclass"] = StaticPool

    engine = create_engine(resolved_database_url, **engine_options)
    session_factory = sessionmaker(
        bind=engine, autoflush=False, expire_on_commit=False
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        Base.metadata.create_all(bind=engine)
        yield
        engine.dispose()

    app = FastAPI(title="to-do-list-api", version=resolved_version, lifespan=lifespan)
    app.state.session_factory = session_factory
    app.state.version = resolved_version

    @app.get("/tasks", response_model=list[TaskRead])
    def list_tasks(db: DatabaseSession) -> list[Task]:
        return list(db.scalars(select(Task).order_by(Task.id)).all())

    @app.post("/tasks", response_model=TaskRead, status_code=status.HTTP_201_CREATED)
    def create_task(task: TaskCreate, db: DatabaseSession) -> Task:
        new_task = Task(title=task.title, description=task.description)
        db.add(new_task)
        db.commit()
        db.refresh(new_task)
        _publish_metric("TasksCreated")
        return new_task

    @app.get("/version", response_model=VersionResponse)
    def get_version(request: Request) -> VersionResponse:
        return VersionResponse(version=request.app.state.version)

    @app.get("/health", response_model=HealthResponse)
    def get_health(
        request: Request, db: DatabaseSession
    ) -> HealthResponse | JSONResponse:
        timestamp = datetime.now(timezone.utc)
        try:
            db.execute(text("SELECT 1"))
        except SQLAlchemyError:
            logger.exception("Database health check failed")
            _record_database_error()
            return JSONResponse(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                content={
                    "status": "FAIL",
                    "version": request.app.state.version,
                    "timestamp": timestamp.isoformat(),
                },
            )

        return HealthResponse(
            status="OK", version=request.app.state.version, timestamp=timestamp
        )

    return app


app = create_app()