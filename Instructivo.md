# Instructivo de Uso y Configuración
### Charly App · Asistente Computacional para Análisis Psicométrico en R

---

## 1. Introducción y Propósito

**Charly App** es una herramienta de escritorio orientada a la investigación y la docencia, concebida para asistir en la especificación, ejecución y verificación de modelos psicométricos y estadísticos en lenguaje **R**.

El software permite que el usuario redacte su necesidad metodológica en lenguaje natural (por ejemplo: *"En Base_A.xlsx, estimá un AFC de primer orden con WLSMV para los factores Operativo, Relacional, Estratégico y Liderazgo, e invertí el reactivo I8"*). A partir de allí, el sistema:

1. Perfila empíricamente las variables de la base de datos seleccionada.
2. Identifica el arquetipo metodológico canónico y consulta de forma interactiva los criterios de estimación e higiene de datos.
3. Genera un script formal en R utilizando librerías validadas (`lavaan`, `psych`, `MASS`, `semTools`, `readxl`).
4. Ejecuta el script localmente en el entorno R del equipo del usuario, audita el ajuste del modelo y abre el código fuente en RStudio para garantizar la total reproducibilidad de los resultados.

### ¿Qué significa "Ejecución Local y Reproducible"?
* **Cómputo 100% local en R:** Todos los cálculos matemáticos, matrices de correlación policórica, estimaciones de parámetros y ajustes se resuelven exclusivamente dentro de tu propia computadora a través de tu instalación local de R.
* **Reproducibilidad científica:** A diferencia de los chatbots convencionales de inteligencia artificial que entregan textos o números no verificables, Charly produce un script sintáctico en R (`workspace/generated_script.R`). Ese script puede ser inspeccionado, auditado y vuelto a correr de forma independiente en RStudio en cualquier momento, obteniendo con exactitud los mismos resultados.
* **Modalidad Offline vs. Nube:** 
  - Si utilizás el **Modo Local (Seru Girán / llama-server / Ollama)**, todo el flujo es **100% Offline**, sin necesidad de conexión a internet ni envío de datos fuera de tu equipo.
  - Si utilizás el **Modo Nube (Google Gemini)**, la traducción de la consigna a código R requiere conexión, pero el análisis estadístico y los datos numéricos se procesan de forma estrictamente local en tu computadora.

---

## 2. Instalación Inicial Paso a Paso

Si recibiste el enlace del repositorio por correo o mensaje de texto, el procedimiento de instalación en Windows requiere los siguientes pasos:

1. **Descargar el repositorio**:
   * En la página de GitHub, hacé clic en el botón verde **`<> Code`** (arriba a la derecha).
   * Seleccioná la opción **`Download ZIP`**.
2. **Descomprimir la carpeta**:
   * Hacé clic derecho sobre el archivo descargado y seleccioná *Extraer todo...*.
   * Elegí una ubicación cómoda en tu equipo (por ejemplo, en tu *Escritorio* o en *Documentos*).
3. **Ejecutar el instalador automático**:
   * Abrí la carpeta descomprimida `Charly_App` y hacé doble clic en el archivo **`Instalar_Charly_App.bat`**.
   * Este instalador:
     - Comprueba que tengas instalado Python (versión 3.10 o superior).
     - Instala las dependencias necesarias de interfaz gráfica (`PySide6`, `python-docx`).
     - Genera un acceso directo en tu Escritorio para que puedas abrir Charly App en cualquier momento.

*(Para aperturas posteriores, podés usar el acceso directo del Escritorio o hacer doble clic en `Iniciar_Charly_App.bat`).*

---

## 3. Configuración del Entorno R y Paquetes Estadísticos

Charly App no simula cálculos: ejecuta análisis reales en tu propia computadora mediante el motor de **R**.

1. **Verificar que R esté instalado**:
   * Si aún no tenés R en tu equipo, descargalo de forma libre y gratuita desde el sitio oficial de CRAN:  
     👉 [https://cloud.r-project.org/](https://cloud.r-project.org/)
2. **Instalación de paquetes de R en 1 clic**:
   * Al abrir Charly App, dirigite a la pestaña **⚙️ Configurar R e IA**.
   * Presioná el botón **`📦 2. Comprobar e Instalar Paquetes de R Automáticamente`**.
   * El sistema comprobará la presencia de las librerías estadísticas necesarias (`lavaan`, `psych`, `MASS`, `semTools`, `readxl`, `writexl`, `openxlsx`, `ggplot2`, `GPArotation`) e instalará de forma desatendida aquellas que falten.

---

## 4. Configuración del Motor de Inteligencia Artificial

Charly App ofrece dos modalidades para interpretar consignas metodológicas:

### Modalidad A: Vía Nube con Google Gemini (Gratis y Recomendada)
* **Ventajas**: Rápida, no consume recursos computacionales de tu máquina ni requiere placas de video dedicadas.
* **Costo**: Totalmente gratuita mediante el nivel sin costo de Google AI Studio (no requiere ingresar tarjeta de crédito).
* **Cómo obtener tu clave**:
  1. Ingresá en [https://aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey) con tu cuenta de Google.
  2. Presioná *Create API Key* y copiá la cadena generada.
  3. En Charly App (pestaña *⚙️ Configurar R e IA*), pegá la clave en el casillero correspondiente y presioná *💾 Guardar y Probar Conexión Nube*.
  4. Tu clave queda almacenada de forma segura mediante la API de Protección de Datos de Windows (**DPAPI**), cifrada exclusivamente para tu usuario.

### Modalidad B: Vía Local Offline con Seru Girán (Privacidad Total)
* **Ventajas**: 100% desconectada de internet. Ningún dato ni nombre de variable sale de tu equipo.
* **Requisitos**: Computadora con procesador de alto rendimiento y al menos 16 a 32 GB de memoria RAM.
* **Funcionamiento**: Compatible con servidores locales con API estándar de OpenAI: `llama-server` (puerto `8090`), `Ollama` (puerto `11434`) o `LM Studio` (puerto `1234`).

---

## 5. Gestión de Bases de Datos: ¿Cómo descargar y usar las bases de prueba?

### ¿Cómo accede el estudiante o investigador a las bases de datos?
Al descargar el archivo comprimido del repositorio (**`Download ZIP`**), **todas las bases de datos de prueba ya vienen incluidas** dentro de la subcarpeta:
```
Charly_App/datasets_ejemplo/
```
Junto a las bases, se incluye una guía explicativa de variables (archivo **`LEEME_BASES.txt`**) que detalla qué mide cada ítem y columna. **No es necesario descargar archivos adicionales ni moverlos de lugar.** Charly App incorpora un buscador automático que rastrea los archivos directamente en esa carpeta.

### Bases de datos anónimas incluidas:
Para garantizar la confidencialidad en internet, las bases han sido anonimizadas bajo las siguientes nomenclaturas:

1. **`Base_A.xlsx`** (Hoja única: **`RESPUESTAS`**, $N = 591$, 30 columnas):
   * Incluye 24 reactivos psicométricos tipo Likert en escala ordinal de 1 a 6 (`I2` a `I49`: `I2, I3, I4, I7, I8, I9, I11, I12, I14, I17, I18, I20, I30, I33, I37, I22, I23, I24, I38, I40, I43, I47, I48, I49`), donde el valor `7` corresponde a *"No aplica"* para recodificar como `NA`.
   * Incluye covariables demográficas (`EDAD`, `GENERO` [1=Femenino, 2=Masculino, 3=Otro, 4=Prefiero no contestar], `COBERTURA` [1=Plan de Salud, 2=Obra Social/Prepaga], `NIVEL_EDUCATIVO` [1 a 6]), `RECOMENDACION` (0 a 10) y `SEDE`.
   * Es la base utilizada en la mayoría de las consignas de AFC, Modelos Bifactoriales, MIMIC, SEM, ACP, AFE y Regresiones.
2. **`Base_B.xlsx`** (Hoja **`Hoja1`**, $N = 306$, 29 columnas):
   * Contiene los mismos 24 reactivos tipo Likert (`I2` a `I49`, escala de 1 a 6), las variables sociodemográficas en minúscula (`edad`, `genero`, `cobert`, `educa`) y `Recomen` (0 a 10).
   * Utilizada en tareas de replicación empírica, modelos jerárquicos, regresiones y senderos no recursivos con bucles.
3. **`Base_C.xlsx`** (Hoja **`Hoja1`**, $N = 148$ observaciones válidas):
   * Matriz con covariables (`Edad`, `Genero`, `Educacion`), reactivos de bienestar (`x1` a `x12`, escala de 0 a 4), `pr0pu1` (0/1), indicadores binarios (`var61` a `var72`) y puntajes continuos (`meaning.`, `peace.`, `faith.`, `BE.`).
   * Utilizada en modelos MIMIC de segundo orden con correlación residual entre ítems específicos (`x10 ~~ x11`).

### ¿Dónde busca Charly tus archivos si usás datos propios?
Si deseás analizar tus propias bases de datos, no necesitás tipear rutas complejas. Basta con colocar tu archivo en cualquiera de estas ubicaciones y mencionarlo en la consigna:
1. La subcarpeta **`datasets_ejemplo/`** de Charly App.
2. La carpeta raíz de **`Charly_App`**.
3. Tu carpeta de **Descargas** (`Downloads`).
4. Tu **Escritorio** (`Desktop` o `Escritorio`), tanto local como en OneDrive.
5. Tu carpeta de **Documentos** (`Documents` o `Documentos`).

**Formatos admitidos**: Excel (`.xlsx`, `.xls`), SPSS (`.sav`), valores separados por coma (`.csv`) y archivos nativos de R (`.rds`).

---

## 6. Flujo de Trabajo: Cómo Correr tu Primer Análisis

1. **Seleccionar o redactar la consigna**:
   * Podés redactar tu consulta en lenguaje natural o elegir cualquiera de las **47 consignas metodológicas probadas** disponibles en el archivo **`Catalogo_Consignas_Charly.html`** (accesible mediante el botón superior *📖 Catálogo de Ejemplos*).
2. **Copiar y pegar la consigna**:
   * En el catálogo, hacé clic en el botón verde **`📋 Copiar`** de la consigna deseada.
   * En Charly App, pegá el texto en la caja de texto principal y presioná **`Ejecutar Análisis`**.
3. **Ejecución y verificación**:
   * Charly perfila la base de datos, verifica tipos de variables y valores faltantes.
   * Redacta el script sintáctico en R (`workspace/generated_script.R`).
   * Ejecuta el script localmente y captura los resultados numéricos.
   * Genera automáticamente un informe académico en formato Word (`.docx`).
4. **Inspección en RStudio**:
   * Si tenés RStudio instalado, el script generado (`workspace/generated_script.R`) se abrirá automáticamente en el **panel superior izquierdo (editor de scripts)**.
   * Para correrlo de forma interactiva, consultar `warnings()` o revisar la consola de R, presioná el botón **`[Source]`** (o el atajo **`Ctrl + Shift + S`**).
   * También podés auditar o ejecutar el código línea por línea seleccionando las instrucciones y presionando **`Ctrl + Enter`** (útil para ver qué calcula cada renglón paso a paso sin correr todo el programa de golpe).

---

## 7. Preguntas Frecuentes y Diagnóstico

* **¿Qué hago si Charly me indica que Rscript no fue encontrado?**
  * Dirigite a la pestaña *⚙️ Configurar R e IA* y pulsá *📂 Buscar R...*. Seleccioná la ruta donde instalaste R (habitualmente `C:\Program Files\R\R-4.x.x\bin\Rscript.exe`).
* **¿Qué ocurre si una consigna menciona valores 7 o ítems invertidos?**
  * Charly aplica automáticamente las fórmulas de higiene solicitadas: recodifica valores como `NA` e invierte la escala mediante la transformación canónica `(Max + Min) - X`.
* **¿Puedo interrumpir un análisis largo?**
  * Sí, podés presionar en cualquier momento el botón **`⛔ Cancelar`** en la barra superior.

---

*Proyecto de asistencia para la investigación científica y la docencia universitaria.*
