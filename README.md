**Español** | [English](README.en.md)

# GLPI Docker Manager

Instala y administra GLPI en Linux desde un menú interactivo, con imágenes
oficiales de Docker e interfaz en español e inglés.

Versión **1.0.2** · [Licencia MIT](LICENSE)

![Menú principal de GLPI Docker Manager en español](docs/images/main-menu-es.png)

*Menú principal con datos de demostración.*

[Ver el tutorial en video](https://youtu.be/o93phEdGLJM)

## Qué puedes hacer

- Elegir la versión de GLPI y configurar IP, puertos, zona horaria y credenciales.
- Usar HTTPS con CA local, Let's Encrypt o certificados propios.
- Actualizar GLPI y cambiar de rama con respaldo y ensayo previo; actualizar
  parches de MySQL y el proxy Caddy por separado.
- Crear respaldos manuales o programados, restaurarlos y trasladar la instalación.
- Consultar servicios y registros, administrar el acceso a MySQL y liberar espacio.
- Instalar el agente Linux en otros equipos mediante un comando generado por el gestor.

## Inicio rápido

Necesitas un servidor Linux con acceso **sudo/root**. El asistente comprueba los
requisitos y ofrece instalar Docker y las dependencias que falten.

```bash
git clone https://github.com/solqubit/glpi-docker-manager.git
cd glpi-docker-manager
chmod +x start.sh
sudo ./start.sh
```

Elige el idioma y sigue el asistente. Al terminar verás la URL para abrir GLPI y
las instrucciones de acceso. Cambia las contraseñas iniciales de GLPI después de
iniciar sesión.

Utiliza **↑ / ↓** para moverte, **Enter** para seleccionar y **Esc** para volver.

## Después de instalar

Puedes abrir de nuevo el menú desde la carpeta del proyecto:

```bash
sudo ./start.sh
```

O desde cualquier ubicación, usando el gestor instalado:

```bash
sudo /opt/glpi-docker-manager/start.sh
```

Ambas opciones administran la misma instalación y conservan sus datos.

La configuración, los datos administrados, los certificados y los respaldos se
guardan en **`/opt/glpi-docker-manager/`**, fuera del repositorio descargado.

## Más información

Los detalles técnicos están en la documentación en inglés:

- [Compatibilidad y requisitos](docs/compatibility.md) · [Uso del menú](docs/interface.md)
- [HTTPS y certificados](docs/https.md) · [Agente Linux automático](docs/linux-agent.md)
- [Respaldos, actualizaciones y recuperación](docs/data-operations.md)
- [Solución de problemas](docs/troubleshooting.md)
- [Pruebas y validación](docs/validation.md) · [Contribuir](CONTRIBUTING.md)

Proyecto independiente. GLPI, MySQL y Caddy conservan sus propias licencias.
