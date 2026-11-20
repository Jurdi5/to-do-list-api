from datetime import datetime

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from src.main import _database_url_from_environment, _publish_metric, create_app


@pytest.fixture
def client(tmp_path):
    app = create_app(
        database_url=f"sqlite:///{tmp_path / 'tasks.db'}",
        version="test-version",
    )
    with TestClient(app, raise_server_exceptions=False) as test_client:
        yield test_client


def test_tasks_can_be_created_and_listed(client):
    assert client.get("/tasks").status_code == 200
    assert client.get("/tasks").json() == []

    response = client.post(
        "/tasks",
        json={"title": "  Comprar leche  ", "description": "Para el desayuno"},
    )

    assert response.status_code == 201
    task = response.json()
    assert task["title"] == "Comprar leche"
    assert task["description"] == "Para el desayuno"
    assert task["completed"] is False
    assert task["id"] == 1
    assert datetime.fromisoformat(task["created_at"])

    listed_tasks = client.get("/tasks").json()
    assert len(listed_tasks) == 1
    assert listed_tasks[0] == task


def test_create_task_rejects_blank_title(client):
    response = client.post("/tasks", json={"title": "   "})

    assert response.status_code == 422
    assert client.get("/tasks").json() == []


def test_version_is_read_from_app_configuration(client):
    response = client.get("/version")

    assert response.status_code == 200
    assert response.json() == {"version": "test-version"}


def test_health_reports_database_status_version_and_timestamp(client):
    response = client.get("/health")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "OK"
    assert body["version"] == "test-version"
    assert datetime.fromisoformat(body["timestamp"])


def test_health_reports_database_failure(client, monkeypatch):
    def fail_execute(
        _session: Session, *_args: object, **_kwargs: object
    ) -> None:
        del _session, _args, _kwargs
        raise OperationalError("SELECT 1", {}, Exception("database unavailable"))

    monkeypatch.setattr(Session, "execute", fail_execute)

    response = client.get("/health")

    assert response.status_code == 503
    body = response.json()
    assert body["status"] == "FAIL"
    assert body["version"] == "test-version"
    assert datetime.fromisoformat(body["timestamp"])
    assert response.headers["content-type"] == "application/json"


def test_task_creation_emits_behavior_metric(client, monkeypatch):
    published_metrics = []
    monkeypatch.setattr(
        "src.main._publish_metric",
        lambda metric_name, value=1: published_metrics.append((metric_name, value)),
    )

    response = client.post("/tasks", json={"title": "Una tarea"})

    assert response.status_code == 201
    assert published_metrics == [("TasksCreated", 1)]


def test_health_emits_metric_when_database_is_unavailable(client, monkeypatch):
    published_metrics = []
    monkeypatch.setattr(
        "src.main._publish_metric",
        lambda metric_name, value=1: published_metrics.append((metric_name, value)),
    )

    def fail_execute(
        _session: Session, *_args: object, **_kwargs: object
    ) -> None:
        del _session, _args, _kwargs
        raise OperationalError("SELECT 1", {}, Exception("database unavailable"))

    monkeypatch.setattr(Session, "execute", fail_execute)

    response = client.get("/health")

    assert response.status_code == 503
    assert published_metrics == [("DatabaseOperationErrors", 1)]


def test_database_url_uses_secret_manager_credentials(monkeypatch):
    class SecretsManager:
        def get_secret_value(self, *, SecretId):
            assert SecretId == "secret-arn"
            return {
                "SecretString": (
                    '{"username":"db-user","password":"sensitive",'
                    '"port":5432}'
                )
            }

    class FakeBoto3:
        @staticmethod
        def client(service_name: str, *, region_name: str) -> SecretsManager:
            assert service_name == "secretsmanager"
            assert region_name == "us-east-1"
            return SecretsManager()

    monkeypatch.setattr("src.main.boto3", FakeBoto3)
    monkeypatch.setenv("DB_SECRET_ARN", "secret-arn")
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("DB_NAME", "todolist")
    monkeypatch.setenv("DB_HOST", "rds.example")
    monkeypatch.delenv("DATABASE_URL", raising=False)

    database_url = _database_url_from_environment()

    assert database_url.drivername == "postgresql+psycopg2"
    assert database_url.username == "db-user"
    assert database_url.password == "sensitive"
    assert database_url.host == "rds.example"
    assert database_url.database == "todolist"


def test_database_write_failure_emits_error_metric(client, monkeypatch):
    published_metrics = []
    monkeypatch.setattr(
        "src.main._publish_metric",
        lambda metric_name, value=1: published_metrics.append((metric_name, value)),
    )

    def fail_commit(_session: Session) -> None:
        del _session
        raise OperationalError("INSERT", {}, Exception("database unavailable"))

    monkeypatch.setattr(Session, "commit", fail_commit)

    response = client.post("/tasks", json={"title": "Una tarea"})

    assert response.status_code == 500
    assert published_metrics == [("DatabaseOperationErrors", 1)]


def test_publish_metric_uses_cloudwatch_put_metric_data(monkeypatch):
    requests = []

    class CloudWatch:
        def put_metric_data(self, **kwargs):
            requests.append(kwargs)

    class FakeBoto3:
        @staticmethod
        def client(service_name: str, *, region_name: str) -> CloudWatch:
            assert service_name == "cloudwatch"
            assert region_name == "us-east-1"
            return CloudWatch()

    monkeypatch.setattr("src.main.boto3", FakeBoto3)
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("METRICS_NAMESPACE", "ToDoListApi")
    monkeypatch.setenv("METRICS_SERVICE", "test-service")

    _publish_metric("DatabaseOperationErrors")

    assert requests == [
        {
            "Namespace": "ToDoListApi",
            "MetricData": [
                {
                    "MetricName": "DatabaseOperationErrors",
                    "Dimensions": [{"Name": "Service", "Value": "test-service"}],
                    "Value": 1,
                    "Unit": "Count",
                }
            ],
        }
    ]