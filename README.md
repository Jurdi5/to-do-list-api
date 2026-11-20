# to-do-list-api

API REST para registrar y consultar tareas. En AWS, Terraform despliega la aplicación en EC2 y guarda las tareas en PostgreSQL RDS.

## Requisitos

- Python 3.10 o posterior
- PostgreSQL (RDS para despliegues) o SQLite para desarrollo local

## Instalación y ejecución local

Desde la carpeta `to-do-list-api`:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r src\requirements.txt
uvicorn src.main:app --reload
```

Sin configuración de base de datos, la API usa `./tasks.db` (SQLite).

## Configuración

`APP_VERSION` define el valor que entrega `GET /version` y que incluye `GET /health`. Su valor predeterminado es `dev`.

En desarrollo, para conectarte directamente a PostgreSQL puedes configurar `DATABASE_URL`, por ejemplo:

```text
postgresql+psycopg2://usuario:contraseña@host-rds:5432/tareas
```

En AWS, la aplicación lee las credenciales de `DB_SECRET_ARN` con el rol de instancia. Terraform asigna a EC2 permisos mínimos para consultar ese secreto y publicar métricas. La contraseña no se configura en el repositorio ni se pasa por GitHub Actions.

## Endpoints

| Método | Ruta | Comportamiento |
|---|---|---|
| `GET` | `/tasks` | Devuelve las tareas registradas, ordenadas por identificador. |
| `POST` | `/tasks` | Crea una tarea; requiere `title` y acepta `description`. Devuelve `201`. |
| `GET` | `/version` | Devuelve `{"version": "..."}` según `APP_VERSION`. |
| `GET` | `/health` | Comprueba la conexión a la base de datos y devuelve `status`, `version` y `timestamp`. Si falla la conexión, devuelve `503` y `status: "FAIL"`. |

Ejemplo para crear una tarea:

```json
{
  "title": "Preparar entrega",
  "description": "Revisar el proyecto antes de enviarlo"
}
```

La documentación interactiva de FastAPI está disponible en `/docs`.

## Pruebas

```powershell
pip install pytest httpx
python -m pytest
```

## Infraestructura en AWS

`terraform/` crea la EC2, los Security Groups, un Key Pair, RDS PostgreSQL privado, el secreto administrado por RDS en Secrets Manager, SNS, las alarmas y el dashboard. En Learner Lab, la EC2 usa el instance profile preexistente asociado a `LabRole`; Terraform no crea ni modifica roles IAM. El nombre predeterminado del instance profile es `LabInstanceProfile`; cámbialo con `-var="lab_instance_profile_name=..."` si tu consola muestra otro nombre. El rol debe tener permisos para leer el secreto RDS, publicar métricas en CloudWatch y conectarse a Systems Manager. `terraform/main.tf` configura el backend S3 `to-do-list-p4-state` en `us-east-1`; el bucket debe existir en esa región antes de inicializar Terraform. Protege ese bucket con versionado, cifrado y acceso restringido al equipo. El backend usa bloqueo nativo de S3 (`use_lockfile`) y el estado nunca debe subirse al repositorio.

Desde PowerShell, en la raíz del repositorio:

```powershell
cd terraform
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
terraform output api_url
```

La cuenta debe tener permisos de Learner Lab para EC2, RDS, Secrets Manager, CloudWatch y SNS, permiso para pasar el instance profile existente a EC2, y una VPC predeterminada con subredes en al menos dos zonas de disponibilidad. La EC2 descarga este repositorio público durante el arranque, instala sus dependencias, configura Nginx/systemd y arranca la API sin acceso SSH. El puerto 22 no está abierto por defecto. Terraform genera un par de llaves; el output `ssh_private_key_pem` es sensible y queda en el estado remoto, así que restringe el acceso al estado.

La instancia RDS no es pública y solo acepta PostgreSQL desde el Security Group de la API. RDS administra la contraseña maestra en Secrets Manager. **`terraform destroy` elimina también RDS y sus datos.**

Después de aplicar:

1. Confirma la suscripción al tópico SNS desde el correo indicado por `alert_email`.
2. Espera a que termine el `user_data` y comprueba `terraform output -raw api_url` seguido de `/health` y `/version`.
3. Las alarmas no enviarán correo mientras no confirmes el correo de SNS.

## Caso 2: inicialización en Ubuntu

Estos pasos se ejecutan desde la terminal de Ubuntu, en la raíz del repositorio. La aplicación local usa SQLite; para desplegar en AWS sigue también la sección de Terraform. La EC2 que crea la configuración actual usa Amazon Linux 2023, aunque ejecutes Terraform desde Ubuntu.

### Ejecutar y probar la API localmente

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip curl
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r src/requirements.txt
APP_VERSION=ubuntu-local uvicorn src.main:app --host 127.0.0.1 --port 8000
```

Deja esa terminal activa y, en otra terminal, prueba los endpoints:

```bash
curl -i http://127.0.0.1:8000/health
curl -i http://127.0.0.1:8000/version
curl -i -X POST http://127.0.0.1:8000/tasks \
  -H "Content-Type: application/json" \
  -d '{"title":"Tarea desde Ubuntu","description":"Prueba local"}'
curl -i http://127.0.0.1:8000/tasks
```

### Provisionar AWS con Terraform desde Ubuntu

Instala Terraform y AWS CLI:

```bash
sudo apt update
sudo apt install -y wget gpg awscli
wget -O- https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update
sudo apt install -y terraform
terraform version
aws --version
```

Inicia Learner Lab y copia las credenciales temporales de **AWS Details**. Introdúcelas en la terminal; el secreto y el token se solicitan sin mostrarse:

```bash
read -rp "AWS access key ID: " AWS_ACCESS_KEY_ID
read -rsp "AWS secret access key: " AWS_SECRET_ACCESS_KEY; echo
read -rsp "AWS session token: " AWS_SESSION_TOKEN; echo
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_DEFAULT_REGION=us-east-1
aws sts get-caller-identity
```

Las credenciales vencen al terminar la sesión del laboratorio; vuelve a cargarlas cuando expiren. No las guardes en el repositorio ni en capturas.

El bucket S3 `to-do-list-p4-state` debe existir en `us-east-1` antes de `terraform init`, porque contiene el estado remoto:

```bash
aws s3api head-bucket --bucket to-do-list-p4-state
```

Si no existe, créalo una sola vez como bucket de backend (por consola o con una configuración Terraform de bootstrap separada) y habilita versionado y cifrado. No destruyas ese bucket junto con la aplicación.

Desde la raíz del repositorio, inicializa y aplica Terraform. El perfil predeterminado es `LabInstanceProfile`; si tu Learner Lab muestra otro instance profile asociado a `LabRole`, sustituye ese valor:

```bash
cd terraform
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan -var="lab_instance_profile_name=LabInstanceProfile"
terraform apply tfplan
```

Cuando termine, prueba la API en EC2. El Security Group expone HTTP por el puerto 80; no agregues `:8000` a esta URL:

```bash
API_URL="$(terraform output -raw api_url)"
curl -i "$API_URL/health"
curl -i "$API_URL/version"
curl -i -X POST "$API_URL/tasks" \
  -H "Content-Type: application/json" \
  -d '{"title":"Tarea en RDS","description":"Prueba desplegada"}'
curl -i "$API_URL/tasks"
```

Para eliminar los recursos creados por esta configuración, desde `terraform/` y con credenciales válidas del laboratorio:

```bash
terraform destroy -var="lab_instance_profile_name=LabInstanceProfile"
```

Usa el mismo nombre de instance profile con el que aplicaste Terraform. **Esto elimina EC2, RDS y sus datos; hazlo solo después de guardar todas las evidencias.** El bucket S3 del backend no se elimina.

## CI, releases y despliegues

`.github/workflows/ci.yml` corre las pruebas en cada Pull Request a `main` y en cada push a `main`. Para impedir merges con pruebas fallidas, configura en GitHub **Settings → Rules → Rulesets** (o **Branches → Branch protection rules**) una regla para `main`: exige Pull Request y el status check **`CI / unit-tests`**, y bloquea los pushes directos/bypass según la política del repositorio. El workflow no puede activar esta regla por sí mismo; se configura en los ajustes del repositorio.

Para que Continuous Deployment pueda acceder al Learner Lab, agrega en **Settings → Secrets and variables → Actions**:

- Secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y `AWS_SESSION_TOKEN` tomados de la sesión activa de Learner Lab.
- Secret `RELEASE_TOKEN` con un token de GitHub limitado al repositorio y permiso `Contents: Read and write`; se usa para publicar el release y disparar Continuous Deployment.
- Variable `AWS_REGION` con valor `us-east-1` (también es el valor predeterminado del workflow).

Las credenciales de Learner Lab vencen; actualiza los tres secrets antes de publicar un release si la sesión expiró. El deploy usa Systems Manager, no SSH, y requiere que exista una instancia EC2 activa del proyecto.

Al empujar una etiqueta `vMAJOR.MINOR.PATCH` (por ejemplo `v1.2.0`), Continuous Delivery crea un GitHub Release adjuntando `to-do-list-api.zip`. Al publicarse el release, Continuous Deployment descarga ese artefacto desde la instancia, instala sus dependencias, reinicia systemd y valida `GET /version` contra la etiqueta.

```powershell
git tag v1.2.0
git push origin v1.2.0
```

El repositorio debe mantenerse público para que el arranque y la instancia puedan descargar el código y el artefacto de release sin almacenar un token de GitHub en EC2.

### Workflows de infraestructura y health check

En **GitHub → Actions**, ejecuta manualmente **Provision infrastructure** para inicializar/aplicar Terraform o **Destroy infrastructure** para eliminar los recursos. El workflow de destrucción exige escribir `destroy` como confirmación y borra RDS junto con sus datos; no elimina el bucket remoto S3. Ambos usan los secrets AWS anteriores y el input `lab_instance_profile_name`, que debe coincidir con el instance profile existente de Learner Lab.

El workflow **API health check** se ejecuta manualmente o cada cinco minutos. Configura en **Settings → Secrets and variables → Actions → Variables** la variable `API_URL` con la URL base obtenida de `terraform output -raw api_url` (sin `/health` ni `/version`). Si reemplazas la instancia, actualiza este valor. El check verifica que `/health` devuelva `status: OK` y que `/version` incluya una versión.

`alerting/cloudwatch-dashboard.json` y `alerting/alarms.json` son plantillas consumidas por Terraform; los valores de región, instancia, servicio y tópico se completan desde el estado al aplicar la infraestructura.

## CloudWatch y validación de alarmas

Terraform crea el dashboard `to-do-list-api-dashboard` y conecta las tres alarmas al mismo tópico SNS:

| Métrica | Tipo | Condición de alarma | Motivo / acción |
|---|---|---|---|
| `AWS/EC2` → `CPUUtilization` | Nativa de EC2 | Promedio ≥ 80% durante dos periodos de 5 minutos | Evita alertar por picos breves; investigar carga y capacidad si persiste. |
| `ToDoListApi` → `DatabaseOperationErrors` | Instrumentada por `put_metric_data` | Suma ≥ 1 error en un periodo de 5 minutos | Una sola operación fallida puede indicar una interrupción de RDS; revisar estado y conectividad de la base. |
| `ToDoListApi` → `TasksCreated` | Instrumentada por `put_metric_data` | Suma ≥ 30 tareas en 5 minutos | Detecta un aumento inusual de escrituras; investigar tráfico automatizado o un cambio de uso. Ajustar el umbral al patrón normal. |

Las métricas personalizadas incluyen la dimensión `Service=to-do-list-api`. Si no hay datos, las alarmas personalizadas no se consideran en alarma. El error de base de datos solo se publica al ocurrir una operación fallida; para probarlo, detén RDS desde la consola, llama varias veces a `/health` o intenta crear una tarea, y revisa la métrica/alarma en CloudWatch. Después vuelve a iniciar RDS y verifica que `/health` reporte `OK`. No se detiene RDS automáticamente y esta validación debe realizarse en la cuenta AWS.