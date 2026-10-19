[English](README.md) | [Español](README.es.md)

# GLPI Docker Manager

Gestor interactivo para instalar y administrar GLPI en Linux mediante imágenes
oficiales de Docker. La interfaz está disponible en español e inglés; el código y
la documentación técnica principal están en inglés.

## Inicio rápido

```bash
git clone https://github.com/solqubit/glpi-docker-manager.git
cd glpi-docker-manager
chmod +x start.sh
sudo ./start.sh
```

La instalación y administración requieren sudo/root. Sin esos permisos se muestra
una alerta y el comando exacto antes de modificar el sistema. `help` y `version`
funcionan sin privilegios. El asistente detecta dependencias y ofrece
instalar Docker Engine, Compose y las herramientas necesarias con confirmación.
Si Docker ya funciona, lo reutiliza.

Si el motor está detenido, inicia su servicio mediante systemd, OpenRC o service
según lo disponible y continúa. Ofrece instalar Compose/Buildx desde repositorios
apt/dnf/yum ya configurados. Si una operación de servicio o paquetes falla, muestra
instrucciones y permite reintentar dentro del asistente.

Durante la instalación eliges idioma, rama y versión de GLPI, puertos,
zona horaria, credenciales y HTTPS. El selector consulta versiones estables e
imágenes oficiales, incluidas futuras ramas como GLPI 13. Muestra las tres
versiones instalables más recientes por rama; también admite una versión exacta.
Las comprobaciones oficiales de requisitos deben pasar para instalar o migrar.

Antes de confirmar verás las notas oficiales, avisos de seguridad y una advertencia
especial si eliges GLPI 10, fuera del soporte ordinario. Volver a ejecutar el gestor
abre el menú y conserva los datos y contraseñas existentes.

## Interfaz de terminal

Utiliza **↑ / ↓** para recorrer opciones, **Enter** para elegir y **Esc** para
cancelar o salir de un menú. El idioma, las ramas/versiones, HTTPS y
las confirmaciones se eligen mediante selectores. La configuración permanece en
una sola sección: eliges un campo, lo editas y regresas al mismo campo con el
valor guardado. Se marcan los valores por defecto, los campos validados y las
contraseñas pendientes. La zona horaria ofrece listas buscables de región y
ciudad. Los puertos, dominio y credenciales permiten escribir y editar texto.
Desde la revisión puedes regresar y corregir cualquier dato.

La primera pantalla distingue si aún no hay GLPI, si existe una instalación o si
quedó una operación pendiente. Antes de instalar verás un resumen sin contraseñas.
Después aparecen ocho etapas con su avance y el mensaje verde **GLPI instalado y
verificado**, la URL y los datos del primer acceso. El éxito se muestra después de
comprobar servicios, SQL, esquema y HTTP/HTTPS.

Los mensajes comparten un mismo estilo de marcadores: `[+]` éxito, `[*]`
información, `[!]` aviso, `[✗]` error y `[?]` pregunta. Las etapas largas muestran
un indicador animado con el tiempo transcurrido y el detalle actual (imagen que se
descarga, salud de un servicio, intento de comprobación web). La lista de
versiones de GLPI se guarda 15 minutos y las imágenes se consultan en paralelo, de
modo que las pantallas de versiones y actualización abren mucho más rápido.

El panel agrupa las acciones por categoría y muestra HTTPS y los días que le
quedan al certificado, si MySQL está expuesto, el último respaldo y la
programación de respaldos automáticos. Una tarea diaria (temporizador systemd o
cron) rota los registros, renueva los certificados autofirmados y puede crear
respaldos automáticos (se guardan los 5 más recientes; los manuales nunca se
rotan). El gestor también muestra la caducidad del certificado, desinstala GLPI
de forma limpia y se actualiza desde las versiones publicadas en GitHub. La
configuración propia de GLPI (correo, plugins, acciones automáticas) se hace en
GLPI.

Las notas completas de una versión pueden abrirse desde el selector; los avisos
de seguridad y soporte se muestran siempre. El detalle de instalación se guarda
en registros privados y se indica su ruta si una etapa falla. Hay un modo sencillo
numerado para terminales básicas; `NO_COLOR` conserva las flechas sin colores.

Siempre se instala el mismo GLPI: no hay una clasificación de pruebas/producción.
La advertencia de recursos permite continuar o volver directamente al menú.
El resumen muestra los valores en una tabla, y la opción de MySQL explica que
publicar el puerto 3306 permite conexiones externas. Para una VPS con dominio,
HTTPS público solicita y renueva certificados de **Let's Encrypt** mediante Caddy.

## Qué puedes administrar

* Estado, inicio, parada, registros y diagnóstico.
* Un solo menú para actualizar GLPI: elegir cualquier versión posterior disponible
  de la misma rama, o la siguiente rama con advertencias y confirmación explícita.
* Respaldo y ensayo aislado antes de aplicar cada cambio de versión.
* Publicación de MySQL con Sí/No: exactamente `3306:3306`, configurable después.
* HTTPS autofirmado generado automáticamente, certificado público con renovación
  ACME o certificados propios, al instalar o posteriormente.
* Respaldos de base, archivos, plugins, claves, configuración y certificados.
* Restauración guiada a volúmenes nuevos y traslado a otro servidor.
* Consulta de credenciales bajo confirmación y mantenimiento independiente de
  parches MySQL dentro de la serie 8.4.

## Comandos útiles

```bash
./start.sh --lang es help
sudo ./start.sh status
sudo ./start.sh check-updates
sudo ./start.sh update
sudo ./start.sh backup
sudo ./start.sh backups
sudo ./start.sh restore
sudo ./start.sh restore /ruta/absoluta/respaldo.tar.gz
sudo ./start.sh https
sudo ./start.sh address
sudo ./start.sh db-exposure
sudo ./start.sh transfer
sudo ./start.sh diagnose
```

Sin comandos se abre el menú interactivo. Las operaciones sensibles solicitan
confirmación. Las restauraciones y migraciones principales requieren escribir una
confirmación específica.

## Datos y credenciales

La configuración privada está en `/opt/glpi-docker-manager`, fuera del
repositorio. Toda la instalación queda reunida en esa carpeta:

```text
/opt/glpi-docker-manager/
├── start.sh                 # abrir el gestor instalado
├── manager/                 # código operativo, idiomas y documentación
├── manager-releases/        # revisiones del código del gestor
├── current/                 # configuración activa, .env y Compose
├── revisions/               # revisiones de configuración
├── data/<id>/               # datos reales de GLPI, MySQL, plugins y proxy
├── certs/                   # certificados y claves
├── backups/                 # respaldos disponibles para restaurar
├── logs/                    # registros de las operaciones
└── cache/                   # metadatos de versiones
```

Después de instalar puedes abrirlo con:

```bash
sudo /opt/glpi-docker-manager/start.sh
```

El código se copia dentro de esa raíz; la carpeta descargada de GitHub ya no es
necesaria para administrar GLPI. Ejecutar una copia nueva del repositorio actualiza
el código operativo sin reemplazar datos ni credenciales. Docker monta las carpetas
de `data/` mediante volúmenes etiquetados; no se eliminan durante actualizaciones.
Las imágenes y los componentes del motor Docker siguen administrados por Docker
en el sistema. Los respaldos contienen
secretos: guarda una copia privada fuera del servidor.

Las claves de MySQL se generan o se introducen durante el asistente. Son distintas
de las cuentas web iniciales de GLPI: `glpi/glpi`, `tech/tech`, `normal/normal` y
`post-only/postonly`. Cambia estas cuentas desde GLPI. Editar `.env` por sí solo no
cambia la contraseña ya almacenada en MySQL.

Puedes conservar los valores habituales (`db:3306`, base y usuario `glpi`) o
personalizarlos. HTTP utiliza 80 y HTTPS 443 por defecto para abrir GLPI con la
IP sin escribir el puerto; puedes cambiarlos si están ocupados. Se detecta la IP
de la interfaz de red principal. `address` permite corregir IP, puertos, zona
horaria y HTTPS de una instalación existente. El asistente genera `.env`; elige tus
`GLPI_DB_PASSWORD` y `MYSQL_ROOT_PASSWORD`, sin longitud ni complejidad mínima.
Se ven mientras escribes y Tab permite ocultarlas o mostrarlas. Al aceptar se
borra el campo; dejarlo vacío genera una contraseña automáticamente. La interfaz
utiliza colores ANSI y el módulo opcional `curses` de Python, sin paquetes de pip;
si no está disponible, ofrece opciones numeradas. En una terminal de 80×24 el menú
principal muestra todas las acciones en dos columnas. Estado y registros tienen
vistas propias para evitar tablas extensas debajo del menú.

Los respaldos previos a actualizar aparecen en **Restaurar un respaldo** y
**Administrar respaldos**. Allí puedes consultar detalles, verificar integridad,
exportar una copia o eliminar un archivo concreto escribiendo `DELETE`.
Para restaurar, elige el archivo y confirma escribiendo `RESTORE`:
se recuperan la versión y los datos de ese momento en volúmenes nuevos. Los
cambios posteriores al respaldo no se fusionan. Reducir el número de la imagen
por sí solo no revierte una migración de base de datos.

Antes de generar un respaldo, el gestor estima los datos y el espacio temporal
necesario y los compara con el espacio disponible. Solo después detiene GLPI.
La actualización comprueba además el espacio para el ensayo y las imágenes que
faltan: no exige una reserva fija de 10 GiB. Un respaldo manual y uno previo a
actualizar se identifican por separado en la interfaz.

La contraseña de la aplicación admite comillas, dólares y barras invertidas.
La contraseña de administrador de MySQL excluye comillas y barras invertidas por
el procedimiento inicial de la imagen oficial; el asistente lo explica y puede
generar una contraseña segura automáticamente.

Los certificados importados deben estar exactamente en:

```text
/opt/glpi-docker-manager/certs/custom/fullchain.pem
/opt/glpi-docker-manager/certs/custom/privkey.pem
```

`fullchain.pem` contiene el certificado del dominio seguido de sus intermedios;
`privkey.pem` contiene la clave privada PEM correspondiente sin contraseña. El
asistente comprueba formato, coincidencia, dominio y caducidad. Los autofirmados
se generan automáticamente; debes confiar en el certificado desde tus equipos.

## Compatibilidad y precauciones operativas

Una distribución fuera de la lista puede funcionar si cumple los requisitos.
La [matriz de compatibilidad](docs/compatibility.md) distingue procedimientos de
instalación de Docker y pruebas realizadas. No se inventan repositorios para una
distribución desconocida. Se verifican las imágenes para AMD64 y ARM64.

Una actualización de GLPI puede migrar sus tablas; una actualización de MySQL
cambia el motor. Son operaciones independientes. Volver a una imagen anterior no
garantiza recuperar datos después de una migración. Las restauraciones verifican
el respaldo y crean volúmenes vacíos, conservando los anteriores.

Si se interrumpe una operación, consulta los registros y utiliza `recover` o
restaura un respaldo válido. El ensayo de migración comprueba el esquema, pero
debes revisar plugins, integraciones e inventario y probar tus procesos habituales.

Consulta también [HTTPS](docs/https.md), [respaldos y recuperación](docs/data-operations.md)
y [solución de problemas](docs/troubleshooting.md). La licencia del gestor es MIT;
los componentes conservan sus licencias originales.

## Pruebas locales

Los [resultados de validación](docs/validation.md) detallan las pruebas locales y
sus límites. Las validaciones se ejecutan localmente con Docker, servicios
desechables y credenciales de prueba. No se incluye ningún workflow de GitHub Actions.
