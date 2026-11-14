# Charly App

### Asistente computacional para análisis psicométrico reproducible en R

Charly App es una aplicación de escritorio diseñada para asistir en la formulación, ejecución y verificación de modelos psicométricos y de ecuaciones estructurales en el entorno estadístico **R** (empleando paquetes canónicos como `lavaan`, `psych`, `MASS` y `semTools`), a partir de consignas redactadas en lenguaje natural.

Todo el procesamiento estadístico y el cálculo numérico se ejecutan **de manera local en su propia computadora**. La inteligencia artificial actúa como un transcriptor y asistente de código, permitiendo inspeccionar, auditar y reproducir cada línea de sintaxis generada en RStudio.

---

## Documentación Principal

Si usted accede a este repositorio a través de un enlace (correo electrónico, mensaje o aula virtual), encontrará aquí toda la documentación necesaria para la puesta en marcha:

* 📘 **[Instructivo de Instalación y Uso (HTML)](Instructivo.html)**: Guía detallada paso a paso, accesible directamente desde su navegador web (también disponible en formato [Word (.docx)](Instructivo.docx) y [Markdown (.md)](Instructivo.md)).
* 📋 **[Catálogo de Consignas Canónicas (HTML)](Catalogo_Consignas_Charly.html)**: Compendio de 47 consignas metodológicas calibradas y listas para copiar y pegar (también disponible en formato [Word (.docx)](Catalogo_Consignas_Charly.docx)).
* 🔒 **[Seguridad y Privacidad de Datos](Seguridad.html)**: Explicación técnica sobre el manejo local de datos, cifrado de claves con DPAPI de Windows y ejecución de procesos (también en [Markdown](LEEME_SEGURIDAD.md)).

---

## Requisitos Previos

Antes de ejecutar Charly App, verifique contar con las siguientes herramientas instaladas en su equipo con Windows:

1. **Python 3.10 o superior**:  
   Descarga oficial: [python.org/downloads](https://www.python.org/downloads/)  
   *Nota importante*: Durante la instalación, marque la casilla **"Add python.exe to PATH"** en la primera pantalla.
2. **R (versión 4.3 o superior)**:  
   Descarga oficial desde CRAN: [cloud.r-project.org](https://cloud.r-project.org/)  
   Instale la versión estándar para Windows.
3. **RStudio (opcional pero recomendado)**:  
   Descarga oficial: [posit.co/download/rstudio-desktop](https://posit.co/download/rstudio-desktop/)  
   Permite abrir automáticamente los scripts generados para su revisión interactiva.

---

## Instalación y Puesta en Marcha (3 Pasos)

### Paso 1: Descargar el repositorio
Haga clic en el botón verde superior **`<> Code`** y seleccione **`Download ZIP`**. Descomprima el archivo descargado en una carpeta de su computadora (por ejemplo, en su Escritorio o Documentos).

### Paso 2: Ejecutar el instalador
En la carpeta descomprimida `Charly_App`, haga doble clic sobre el archivo:
```
Instalar_Charly_App.bat
```
Este archivo por lotes realizará de forma automática:
* La comprobación del entorno de Python.
* La instalación de las bibliotecas de interfaz gráfica (`PySide6` y `python-docx`).
* La creación de un acceso directo denominado **Charly App** en su Escritorio.
* El inicio de la aplicación.

*(Para aperturas posteriores, puede utilizar directamente el acceso directo de su Escritorio o hacer doble clic en `Iniciar_Charly_App.bat` dentro de la carpeta).*

### Paso 3: Configurar R y Paquetes
Al abrir Charly App:
1. En la pestaña de configuración, verifique que la ruta a `Rscript.exe` sea detectada automáticamente.
2. Si aún no tiene instalados los paquetes estadísticos de R, presione el botón **`[2] Instalar paquetes de R faltantes`**. La aplicación instalará automáticamente las dependencias necesarias (`lavaan`, `psych`, `MASS`, `semTools`, `readxl`, `writexl`, `openxlsx`, `ggplot2`, `GPArotation`, entre otras).

---

## Configuración del Motor de Inteligencia Artificial

Charly App admite dos modalidades operativas, según sus preferencias y requerimientos de privacidad:

### Opción A: Modo Nube (Google Gemini - Recomendado)
* **Costo**: Gratuito (nivel sin costo para uso personal o académico a través de Google AI Studio).
* **Obtención de clave**: Ingrese con su cuenta de Google en [aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey) y cree una API Key. No se solicita tarjeta de crédito.
* **Seguridad**: Pegue la clave en el campo correspondiente de Charly App. La clave se almacena cifrada localmente mediante la API de Protección de Datos de Windows (**DPAPI**) exclusiva de su usuario, y viaja encriptada vía HTTPS directamente a Google.
* **Privacidad**: Sólo viaja la consigna y la ficha descriptiva de variables (nombres y tipo). No se transmiten filas de datos crudos ni respuestas de participantes.

### Opción B: Modo Local (Offline / Seru Girán)
* **Conexión**: 100% desconectado de internet. No se envía ningún dato fuera de su computadora física.
* **Compatibilidad**: Compatible con servidores locales con API estándar de OpenAI:
  * `llama-server` (puerto por defecto `8090`).
  * `Ollama` (puerto `11434`, modelo por defecto `qwen2.5-coder:32b` o similar).
  * `LM Studio` (puerto `1234`).
* Requiere hardware con memoria suficiente (tarjeta gráfica dedicada o memoria RAM holgada) para la ejecución fluida del modelo local.

---

## Ubicación y Búsqueda de Bases de Datos

### ¿Cómo accede el estudiante a las bases de datos de prueba?
Al descargar el archivo comprimido del repositorio (**`Download ZIP`**), **todas las bases de datos ya vienen incluidas** en la subcarpeta:
```
Charly_App/datasets_ejemplo/
```
Junto a las bases, se incluye una guía explicativa de variables (archivo **`LEEME_BASES.txt`**) que detalla qué mide cada ítem y columna. **No es necesario descargar archivos adicionales ni moverlos de carpeta.** Charly App incorpora un resolvedor inteligente que localiza automáticamente los archivos en `datasets_ejemplo/`.

### Bases de datos anónimas incluidas:
Para asegurar la confidencialidad en internet, las bases de prueba han sido nombradas de forma neutra y estandarizada:
* **`Base_A.xlsx`** (Hoja única: **`RESPUESTAS`**, $N = 591$, 30 columnas): Incluye 24 reactivos psicométricos en escala Likert ordinal de 1 a 6 (`I2, I3, I4, I7, I8, I9, I11, I12, I14, I17, I18, I20, I30, I33, I37, I22, I23, I24, I38, I40, I43, I47, I48, I49`, con código `7 = No aplica` para recodificar como `NA`), las covariables sociodemográficas (`EDAD`, `GENERO`, `COBERTURA`, `NIVEL_EDUCATIVO`), `RECOMENDACION` (0 a 10) y `SEDE`. Utilizada en la mayoría de los análisis factoriales (AFC y Bifactorial), MIMIC, SEM, ACP, AFE y Regresiones.
* **`Base_B.xlsx`** (Hoja **`Hoja1`**, $N = 306$, 29 columnas): Contiene los mismos 24 reactivos tipo Likert (`I2` a `I49`, escala de 1 a 6), las variables sociodemográficas abreviadas (`edad`, `genero`, `cobert`, `educa`) y `Recomen`, empleada en tareas de replicación empírica, modelos de segundo orden y senderos no recursivos con bucles.
* **`Base_C.xlsx`** (Hoja **`Hoja1`**, $N = 148$ observaciones válidas): Escala de bienestar espiritual y subjetivo con reactivos `x1` a `x12` (0 a 4), covariables (`Edad`, `Genero`, `Educacion`, `pr0pu1`), indicadores binarios (`var61` a `var72`) y puntajes continuos (`meaning.`, `peace.`, `faith.`, `BE.`), utilizada en modelos MIMIC con correlación residual entre ítems (`x10 ~~ x11`).

### Búsqueda de bases propias:
Si desea utilizar sus propios datos, basta con guardar su archivo Excel (`.xlsx`), SPSS (`.sav`) o CSV en cualquiera de las siguientes ubicaciones:
1. La subcarpeta **`datasets_ejemplo/`**.
2. La carpeta raíz de **`Charly_App`**.
3. Su carpeta de **Descargas** (`Downloads`).
4. Su **Escritorio** (`Desktop`), incluyendo el Escritorio de OneDrive.
5. Su carpeta de **Documentos** (`Documents`).

---

## Catálogo de Arquetipos Metodológicos

Charly App está configurado para resolver con rigor los **10 arquetipos canónicos** de la psicometría contemporánea:

| N° | Arquetipo | Estimadores / Métodos | Métricas e Índices Generados |
|:--:|:---|:---|:---|
| **1** | **AFC Primer Orden** | WLSMV (ordinal) / MLR (continuo) | Cargas factoriales, Fiabilidad Compuesta (CR), AVE, Fornell-Larcker, Matriz HTMT, Índices de Modificación. |
| **2** | **AFC Segundo Orden** | WLSMV / MLR | Cargas de primer y segundo orden, Fiabilidad de orden superior, integración MIMIC. |
| **3** | **Bifactorial** | WLSMV / MLR (ortogonal) | Factor general y factores específicos, Omega Jerárquico ($\omega_h$), Omega Total ($\omega_t$), ECV, PUC y Omega Específico ($\omega_{hs}$). |
| **4** | **MIMIC & Invarianza / DIF** | Estimación multivariada | Covariables predictoras de factores y reactivos; detección de DIF mediante Score Test de Muthén (1989) a 1 gl con corrección de Bonferroni. |
| **5** | **SEM / Senderos** | Estimación simultánea | Efectos directos, indirectos y contraste de hipótesis de mediación ($A \rightarrow B$). |
| **6** | **SEM / No Recursivo** | Variables instrumentales | Estimación de bucles de retroalimentación y efectos recíprocos ($A \rightleftarrows B$). |
| **7** | **ACP (Componentes Principales)** | `psych::principal()` | Autovalores > 1 (criterio de Kaiser), comunalidades y rotación Varimax. |
| **8** | **AFE (Factorial Exploratorio)** | `psych::fa()` (Minres/WLS) | Análisis paralelo, scree test, cargas factoriales y rotación Oblimin / Promax. |
| **9** | **Regresión Logística** | `glm` / `MASS::polr` | Modelos binarios y ordinales acumulativos, Odds Ratios (OR), intervalos de confianza y p-valores. |
| **10** | **Regresión Probit** | `glm(link="probit")` / `MASS::polr` | Coeficientes z estandarizados, umbrales y significación estadística. |

Consulte el documento **[Catalogo_Consignas_Charly.html](Catalogo_Consignas_Charly.html)** para ver las 47 consignas de ejemplo con sintaxis validada.

---

## Flujo de Trabajo Recomendado

1. Abra el archivo **`Catalogo_Consignas_Charly.html`** en su navegador.
2. Seleccione la técnica o consigna que desea reproducir y presione el botón **`📋 Copiar`**.
3. Inicie **Charly App** (mediante el acceso directo del Escritorio o `Iniciar_Charly_App.bat`).
4. Pegue la consigna en la caja de texto principal y presione **`Ejecutar Análisis`**.
5. Observe la traza de ejecución en la terminal integrada:
   * Charly perfila la base de datos y verifica tipos de variables y valores faltantes.
   * Genera el script sintáctico en R (`workspace/generated_script.R`).
   * Ejecuta el script localmente y captura los resultados numéricos.
   * Genera automáticamente un informe académico en formato Word (`.docx`).
   * Si tiene RStudio instalado, el script (`workspace/generated_script.R`) se abrirá automáticamente en el **panel superior izquierdo (editor de scripts)**. Para ejecutarlo interactivamente, consultar advertencias (`warnings()`) o inspeccionar la consola de R, presione el botón **`[Source]`** (o el atajo **`Ctrl + Shift + S`**). También puede auditar o ejecutar el código línea por línea seleccionando las instrucciones deseadas y presionando **`Ctrl + Enter`** (útil para ver qué calcula cada renglón paso a paso sin correr todo el programa de golpe).

---

## Principios Éticos y Metodológicos

* **Rigor y Transparencia**: La computación estadística es 100% matemática y reside en el entorno de R. No se aceptan aproximaciones estadísticas generadas por lenguaje natural sin su respaldo en la salida de consola de R.
* **Control por el Investigador**: Todo script generado queda disponible en la carpeta de trabajo para ser auditado, adaptado o citado según los estándares de investigación y reproducibilidad científica.
* **Privacidad**: Sus datos no se transfieren a terceros sin su consentimiento explícito; en el modo local, ninguna información abandona su computadora física.

---

*Proyecto de asistencia para la investigación científica y la formación metodológica.*
