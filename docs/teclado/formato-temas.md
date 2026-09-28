# Formato de tema de OpenBoard — `openboardTheme` versión 1

Archivo JSON (UTF-8), extensión sugerida `.openboard-theme.json`. Es lo que exporta OpenBoard («Exportar a archivo…» / «Copiar como JSON») y lo que importa («Importar desde archivo…» / «Pegar del portapapeles»).

```json
{
  "openboardTheme": 1,
  "name": "Mi tema",
  "states": {
    "idle":        { "color": "#2E4A6B", "effect": "shallow-breath", "brightness": 0.55, "speed": 0.25 },
    "viewing":     { "color": "#2E4A6B", "effect": "shallow-breath", "brightness": 0.85, "speed": 0.25 },
    "working":     { "color": "#0C47E9", "effect": "shallow-breath", "brightness": 0.75, "speed": 0.45 },
    "awaiting":    { "color": "#FF6A00", "effect": "shallow-breath", "brightness": 0.95, "speed": 0.75 },
    "stalled":     { "color": "#FF6A00", "effect": "shallow-breath", "brightness": 0.5,  "speed": 0.3 },
    "done":        { "color": "#09B821", "effect": "shallow-breath", "brightness": 0.7,  "speed": 0.25 },
    "error":       { "color": "#D41145", "effect": "breath",         "brightness": 0.9,  "speed": 0.8 },
    "unconfirmed": { "color": "#2E4A6B", "effect": "solid",          "brightness": 0.3,  "speed": 0 }
  },
  "palette": ["#9B30FF", "#00C9A7", "#B4E600", "#D6E4FF"],
  "confirm": "#FFFFFF"
}
```

## Campos

| Campo | Tipo | Obligatorio | Reglas |
|---|---|---|---|
| `openboardTheme` | entero | sí | Debe ser `1`. Otro número → error «versión N no soportada». Ausente → «no es un tema de OpenBoard». |
| `name` | texto | sí | 1–40 caracteres tras recortar espacios. Si ya existe un tema con ese nombre, OpenBoard pide otro (al importar lo propone con un sufijo « 2», « 3»…). |
| `states` | objeto | sí | Exactamente estas 8 claves, todas obligatorias: `idle`, `viewing`, `working`, `awaiting`, `stalled`, `done`, `error`, `unconfirmed`. Claves extra → se ignoran. |
| `states.*.color` | texto `#RRGGBB` (o entero 0–16777215) | sí | Color de **hardware**: el valor que emite el LED, no un color de pantalla. |
| `states.*.effect` | texto | sí | Uno de `solid`, `breath`, `shallow-breath`, `rainbow`, `off`. (`snake` y `gradient` no valen: en una tecla sola se ven apagados.) |
| `states.*.brightness` | número | sí | 0–1. |
| `states.*.speed` | número | no (0) | 0–1. Solo cuenta con efectos animados. |
| `palette` | lista de colores | sí | 1–12 colores `#RRGGBB` (o enteros). Colores de espacio de trabajo, en orden (el orden decide qué color toca a cada espacio). |
| `confirm` | color | sí | Luz de la confirmación de dos pasos. Solo el color: efecto, brillo y ventana siguen siendo los del usuario. |

Cualquier otra clave en la raíz (p. ej. `"$schema"`, `"author"`, `"description"`) se ignora al importar y no se exporta.

Errores de importación: cada uno nombra el campo, p. ej. «falta states.done», «states.error.effect "snake" no es válido», «palette está vacía», «states.idle.color "#12345" no es un color».

## Reglas de legibilidad (avisos, no errores)

Un tema que las incumple **se puede guardar**, pero OpenBoard enseña cada incumplimiento, pide confirmación explícita y marca la tarjeta con ⚠︎. Son las mismas reglas que cumplen los temas de fábrica (`ThemeRules.violations` en `OpenBoardKit/ColorThemes.swift`). Tono en grados HSV; un color con saturación < 0,35 o muy oscuro «no tiene tono».

1. **Significado**
   - `awaiting` y `stalled`: tono cálido de atención, 5–45°.
   - `error`: rojo, 330–10°, y al menos 20° de separación de `awaiting`.
   - `done`: verde, 75–165°. `working`: azul/frío, 180–275°.
   - Esos cinco deben tener tono (no pueden ser grises).
   - `idle`, `viewing`, `unconfirmed` y `confirm` no pueden estar en tonos de atención (5–45° ni 330–10°).
2. **Paleta**
   - Ningún color de `palette` a menos de 20° de tono de un estado del mismo tema (el pad lo saltaría).
   - Cada color de `palette` a ≥ 40 de distancia RGB (0–255 por canal, euclídea) de cada color de estado.
   - Los colores de `palette` entre sí a ≥ 60 de distancia RGB.
3. **Contraste**
   - La luz emitida por `working` (luminancia lineal × `brightness`) ≥ 1,5 × la de `idle`.
   - `viewing` emite más que `idle`.

## Dónde vive dentro de `config.json`

`"customThemes": [ … ]`: cada entrada es el mismo objeto sin `openboardTheme` y con un `"id"` estable añadido (`"custom-<uuid>"`), p. ej. `{"id": "custom-3F2A…", "name": "Mi tema", "states": {…}, "palette": […], "confirm": "#FFFFFF"}`. Una entrada inválida en el archivo se descarta sin tocar las demás.
