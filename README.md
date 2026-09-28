# OpenBoard · edición para clon del Codex Micro + Superset

[English](README.en.md) · **Español**

> **English:** OpenBoard fork for the AliExpress **Codex Micro clone** ("XiaMi Lab | AI Micro",
> "Project2077", USB `303A:8360`), integrated with Superset: workspace-aware session keys, tap
> and hold, per-app profiles, color themes and a Spanish/English UI.
> [Read the English README →](README.en.md)

Fork de [OpenBoard](https://github.com/camwilso/openboard) de Cam Wilson, adaptado a un teclado
**clon** del Codex Micro («Project2077», USB `303A:8360`) y a
**Superset**, donde corren varias sesiones de código a la vez.

Cada tecla de sesión se ilumina según lo que está pasando: trabajando, esperándote, terminó o
falló. De un vistazo sabes qué sesión te necesita, y con una tecla saltas a ella o le respondes.

<p align="center">
  <img src="docs/teclado/capturas/pad/dibujo-pad.png" alt="Dibujo del teclado" width="340">
  <img src="docs/teclado/capturas/pad/foto-pad-real.png" alt="El teclado iluminado" width="340">
</p>

## ¿Tienes este teclado?

Este fork es para el macro pad que se vende en AliExpress como mini teclado mecánico
Bluetooth/USB con batería, clon del Codex Micro:
**[AliExpress · artículo 1005012978606959](https://es.aliexpress.com/item/1005012978606959.html)**.

Cómo reconocerlo:
- En la placa dice **«XiaMi Lab | AI Micro»** y **«Let's build»**.
- En macOS aparece como **«Project2077»** del fabricante «CodexMicro», USB `303A:8360`.
- 16 posiciones: dial plateado, joystick, 6 teclas de sesión translúcidas, las tapas FAST, APPR,
  REJ, BRANCH, MIC, NEW y CODEX, y 3 LED de estado junto a un círculo.

Si el tuyo coincide, OpenBoard original no lo reconoce bien (manda los eventos en otro formato);
este fork sí.

## Qué añade este fork

### Soporte para el clon
- Entiende el protocolo del clon (sobres `method`/`params`, además de `m`/`p` del original).
- El dibujo de la ventana de ajustes reproduce este teclado: dial, joystick, teclas de sesión
  esmeriladas, barra de LED de estado y las tapas FAST, APPR, REJ, BRANCH, MIC, NEW y CODEX.

### Integración con Superset
- **Salta a la terminal exacta** de cada sesión dentro de Superset, no solo al workspace.
- **Las teclas siguen al workspace activo:** si en un workspace hay 2 sesiones se encienden 2;
  al cambiar a otro con 1, se enciende 1. Orden estable y sin huecos.
- **Barrido de luz al cambiar de workspace**, con el color propio de cada workspace, y la tecla 6
  prestada para avisos urgentes de otro workspace.
- **Conexión opcional al servicio local de Superset** (lista blanca cerrada de acciones, solo
  lectura si cambia la versión): sesiones de otros agentes con su propia tecla, rojo cuando
  algo falla, y reconciliación del estado al arrancar.
- Con la conexión activa: **abrir una sesión nueva** en el workspace activo, **mandar un texto o
  interrumpir** una sesión sin cambiar de ventana (modo armado) y **pasar el trabajo a otro
  agente** con el historial de la terminal, siempre con confirmación de dos pasos.

### Teclas
- **Tocar y mantener**: cada tecla puede hacer dos cosas, con el tiempo de mantenido ajustable.
- **Perfiles por app**: el joystick, el dial y las tapas cambian según la app que tengas al frente
  (con Superset al frente, el joystick cambia de workspace y de pestaña).
- **Atajos con repetición** (por ejemplo, Escape ×2 en una sola pulsación).
- **Micrófono que funciona de verdad**: mantiene la tecla de dictado configurada, con
  autorrepetición como un teclado real.
- **Seguridad**: bloquea snippets peligrosos (`/clear`, `/exit`…), no manda ⏎ a ciegas tras un
  snippet, y al arrancar no se fía de las luces guardadas hasta confirmarlas.

### Colores y temas
<p align="center">
  <img src="docs/teclado/capturas/muestras-temas.png" alt="Temas de color" width="720">
</p>

- **5 temas**: Clásico, Gamer, IA, Pop y Claude. En todos, «te espera» es cálido, error rojo,
  terminado verde y trabajando azul; se comprueba con tests.
- **Temas propios**: guardar, duplicar, renombrar, borrar, importar y exportar en JSON
  ([formato](docs/teclado/formato-temas.md)).
- Al elegir un tema, el teclado lo muestra unos segundos antes de aplicarlo.
- [**Diseñador de paletas**](docs/teclado/disenador-paletas.html): una página para diseñar un tema
  sobre el dibujo del teclado, con las reglas marcadas en vivo, y exportarlo.

### Interfaz
<p align="center">
  <img src="docs/teclado/capturas/ajustes-teclas.png" alt="Ajustes de teclas" width="420">
  <img src="docs/teclado/capturas/ajustes-temas.png" alt="Ajustes de temas" width="420">
</p>

- Toda la interfaz en **español o inglés**, a elegir en Ajustes → Dispositivo.
- La ventana de ajustes se adapta al ancho sin tapar el panel de la tecla.

## Compilar

```sh
cd mac
swift run OpenBoardTests          # más de 1000 tests
tools/build-app.sh --install      # firma con tu certificado local si existe
```

Sin certificado de Developer ID, crea uno local con `mac/tools/make-signing-cert.sh` para que
los permisos de macOS se conserven entre compilaciones.

> **Cuidado con el clon:** no abras Work Louder Input ni la app de escritorio del Codex Micro con
> el clon conectado. Este teclado tiene una sola partición de firmware y un flasheo equivocado
> lo deja inservible.

## Créditos y licencia

Basado en [OpenBoard](https://github.com/camwilso/openboard) de Cam Wilson y sus colaboradores,
con licencia MIT (ver [`LICENSE`](LICENSE)). La documentación original de OpenBoard sigue en
[`docs/`](docs/).
