# Codex Monitor

Utilidad local y portable para Windows que muestra en el **System Tray** el estado de consumo de Codex integrado en ChatGPT/Codex Desktop.

> **Unofficial community project.** Codex Monitor is a small Windows tray utility for viewing Codex usage limits locally. It is not affiliated with, endorsed by, or maintained by OpenAI. The current UI is in Spanish.

## Qué hace

- Muestra el porcentaje restante del límite de 5 horas y del límite semanal.
- Usa colores verde, amarillo, rojo y gris para resumir el estado.
- Permite actualización manual y actualización periódica.
- Puede mostrar GPT Reserve, créditos y restablecimientos cuando están disponibles.
- Guarda un histórico local estructurado de cambios de consumo.
- Puede iniciarse con Windows mediante un acceso directo reversible en la carpeta Startup del usuario.

## Requisitos

- Windows.
- ChatGPT/Codex Desktop instalado, funcionando y con una sesión válida.
- PowerShell 7 (`pwsh.exe`) disponible en `PATH`.

El monitor detecta dinámicamente un runtime compatible de Codex bajo la instalación local de Codex Desktop; no depende de una versión concreta ni de una ruta de usuario fija.

## Inicio rápido

1. Clona o descarga este repositorio.
2. Ejecuta `portable\iniciar-monitor.bat`.
3. El icono de Codex Monitor aparecerá en el System Tray.
4. Haz clic derecho sobre el icono para abrir el menú.

El launcher usa rutas relativas, por lo que la carpeta del repositorio puede cambiar entre equipos.

### Sobre `ExecutionPolicy Bypass`

El launcher inicia `pwsh.exe` con `-ExecutionPolicy Bypass` únicamente para ese proceso de PowerShell. No cambia de forma persistente la política de ejecución de Windows ni requiere permisos de administrador. El script ejecutado es `portable\codex-monitor.ps1`, incluido en este repositorio y visible para revisión.

## Uso

- Zona superior del icono: límite de 5 horas.
- Zona inferior del icono: límite semanal.
- Los porcentajes representan **capacidad restante**.
- `Actualizar ahora` hace una actualización manual.
- Durante la actualización manual se muestra `Codex · Actualizando...`.
- Clic derecho para abrir el menú; clic izquierdo sin acción.
- GPT Reserve puede aparecer como información adicional, pero no forma parte del icono.
- El monitor no atribuye actualmente el consumo a un modelo concreto.

## Colores y avisos

Los colores se basan en el porcentaje restante:

- Verde: más del 50%.
- Amarillo: más del 20% y hasta el 50%.
- Rojo: 20% o menos.
- Gris: dato no disponible o desactualizado (`stale`).

Política de avisos:

- 5 horas: verde → amarillo no avisa; la entrada en rojo sí avisa.
- Semanal: la entrada en amarillo avisa, y la entrada en rojo también.
- La primera lectura válida no avisa.
- Mejoras, aumentos o resets no avisan.
- Los errores y estados `stale` no producen falsos avisos.
- Si coinciden dos avisos, se combinan en una única notificación.

## Información disponible

- Límite de 5 horas y límite semanal.
- GPT Reserve, cuando está disponible.
- Balance y estado de créditos.
- Restablecimientos disponibles y su expiración.
- Timestamps y resets correspondientes.

## Histórico local

El monitor conserva un histórico persistente en:

`%LOCALAPPDATA%\CodexMonitor\logs\usage-history.jsonl`

Es un fichero JSON Lines (JSONL) append-only:

- La primera lectura válida genera un evento `baseline`.
- Después se registran cambios de porcentaje de 5 horas y semanal.
- Los aumentos se conservan como `reset_or_increase`.
- Si no cambia ninguno de esos porcentajes, no se añade una línea nueva.
- Los cambios exclusivos de créditos o restablecimientos no generan actualmente un evento independiente.

### Ver histórico

La opción `Ver histórico` del menú contextual genera una vista TXT temporal y regenerable a partir del JSONL. No abre ni modifica directamente el JSONL bruto.

La vista convierte las fechas a la zona horaria local de Windows y presenta de forma legible eventos, porcentajes, cambios, resets/aumentos, créditos y restablecimientos disponibles cuando existen.

El JSONL local sigue siendo la única fuente técnica persistente del histórico.

## Privacidad y arquitectura

Codex Monitor está diseñado para funcionar localmente:

- App-server independiente por `stdio`/JSON-RPC.
- `CODEX_SQLITE_HOME` temporal y aislado.
- No lee directamente credenciales, tokens, cookies, headers ni `auth.json`.
- No comparte SQLite con Codex Desktop.
- No guarda en el histórico email, username, account IDs, respuestas completas del app-server, SQLite, rutas personales ni un modelo inferido.
- Una sola instancia mediante Mutex.
- No modifica la instalación de Codex.

El histórico de consumo permanece en el PC local y no se almacena en GitHub ni se sincroniza entre equipos.

## Diagnóstico

Para obtener un informe pensado para poder compartirlo en una issue utiliza:

`tools\codex-monitor-diagnostic-share.ps1`

Este wrapper ejecuta el diagnóstico técnico y redacta antes de mostrar el JSON:

- rutas locales;
- PID del proceso auxiliar;
- porcentajes y resets de límites;
- plan/tipo de límite;
- saldo y valores de créditos;
- métricas de uso y tokens.

`tools\codex-monitor-diagnostic.ps1` sigue siendo el diagnóstico técnico completo. **No pegues su salida sin revisarla**, porque puede contener rutas locales y valores de uso/créditos de la cuenta.

Ninguno de los dos diagnósticos está diseñado para leer o mostrar credenciales.

## Inicio con Windows

La opción `Activar inicio con Windows` utiliza la carpeta Startup del usuario y crea `Codex Monitor.lnk`.

- Es reversible.
- No requiere administrador.
- No crea un servicio, Scheduled Task ni una entrada `Run` del registro.
- Puede desactivarse desde el propio menú.

El acceso directo no viaja con Git al clonar el repositorio en otro PC; debe activarse desde Codex Monitor en cada máquina.

## Desinstalación

1. Sal de Codex Monitor desde su menú.
2. Si activaste el inicio con Windows, desactívalo primero desde el propio monitor.
3. Elimina la carpeta del repositorio.
4. Opcionalmente, elimina `%LOCALAPPDATA%\CodexMonitor` si también quieres borrar el histórico local.

## Estructura del repositorio

- `portable\codex-monitor.ps1`: aplicación principal.
- `portable\iniciar-monitor.bat`: launcher.
- `tools\codex-monitor-diagnostic.ps1`: diagnóstico técnico completo.
- `tools\codex-monitor-diagnostic-share.ps1`: diagnóstico sanitizado para compartir.
- `assets\codex-monitor.png`: recurso gráfico fuente.
- `assets\codex-monitor.ico`: icono multirresolución para Windows.

## Licencia

Distribuido bajo licencia MIT. Consulta [`LICENSE`](LICENSE).

## Limitaciones actuales

- Solo Windows.
- La interfaz está actualmente en español.
- Depende de interfaces locales de Codex Desktop que pueden cambiar en futuras versiones.
- No atribuye el consumo a un modelo concreto.
