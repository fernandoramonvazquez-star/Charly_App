# Charly App — Seguridad y privacidad (leer antes de usar con datos reales)

Charly es una aplicación de escritorio **local**: genera código R con una IA y **lo ejecuta en tu computadora**.
Esto es lo que significa en la práctica.

## 1. El código R lo escribe una IA y se ejecuta con TUS permisos
- El script que se ejecuta (`workspace/generated_script.R`) lo produce el modelo (Gemini en la nube o tu IA local).
  Corre en tu PC **sin aislamiento**: con los mismos permisos que tu usuario de Windows.
- Antes de ejecutarlo, Charly lo limpia y lo corrige con reglas automáticas, pero **no audita su seguridad**.
- Buena práctica: abrí el script en RStudio (Charly lo abre solo) y leelo si analizás datos sensibles o si el
  modelo propuso algo inesperado (borrar archivos, descargar paquetes, acceso a red, `system()`, `unlink()`…).
- No pegues en la consigna texto de fuentes que no controlás: puede contener instrucciones dirigidas al modelo.

## 2. Qué se ejecuta y con qué política de PowerShell
- Los scripts internos (`charly_core_bundle/*.ps1`) se lanzan con `-ExecutionPolicy Bypass` **solo para cada proceso
  hijo** de Charly. No se cambia la política de tu sistema.
- Los procesos hijos (PowerShell, R, `llama-server`) se pueden cancelar con **⛔ Cancelar** y se cierran al salir.

## 3. Qué sale de tu computadora
| Modo | Qué se envía | A dónde |
|---|---|---|
| **Nube (Gemini)** | Tu consigna + la "ficha técnica" del dataset (nombres de variables, rangos, N, cantidad de NA) + reglas del prompt | Google (generativelanguage.googleapis.com) |
| **Local (llama-server / Ollama / LM Studio)** | Lo mismo, pero **solo a `127.0.0.1`**: no sale de tu PC | Tu propio equipo |

- En las corridas revisadas el prompt **no incluye filas individuales** de la base, pero sí nombres de variables y
  descriptivos. Revisá `workspace/full_prompt.txt` para ver exactamente qué se envía. Si los **nombres de variables**
  o la consigna son sensibles, usá el **modo local**.
- Los resultados (`resultados_analisis.txt`) y las copias de la base (`workspace/datos_analisis.*`) quedan en la
  carpeta de Charly: guardalas en un lugar protegido y borrá `workspace/` al terminar con datos sensibles.
  Si la carpeta está en OneDrive, esos archivos **se sincronizan a la nube**.

## 4. Tu API Key de Google
- Se guarda **cifrada con Windows DPAPI** en `%APPDATA%\Charly_App\settings.json`: solo la puede descifrar **tu usuario
  de Windows en esta PC**. Si copiás ese archivo a otra PC/usuario, la clave no se podrá leer (Charly te lo avisa y
  hay que pegarla de nuevo).
- Si Windows no puede cifrarla, Charly **no la guarda** (nunca la escribe en texto plano).
- Viaja a Google en el **encabezado `x-goog-api-key`** (no en la URL), por HTTPS.
- Dentro de los procesos de Charly se pasa por la variable de entorno `CHARLY_GEMINI_API_KEY`; cualquier programa
  corriendo con tu mismo usuario podría leerla. No ejecutes software no confiable mientras Charly trabaja.
- Si sospechás que se filtró: borrala en https://aistudio.google.com/app/apikey y creá otra.

## 5. Registro de actividad
- `%APPDATA%\Charly_App\charly.log` (rotativo, ~1 MB × 3) registra errores operativos (copias que fallaron, procesos
  que no arrancaron…). **No guarda claves ni contenido de tus datos.**

## 6. Recomendaciones rápidas
1. Datos sensibles → modo **local** y carpeta fuera de OneDrive.
2. Leer el script R antes de confiar en los resultados.
3. No compartir `settings.json` ni la carpeta `workspace/`.
4. Mantener R, los paquetes y Windows actualizados.

