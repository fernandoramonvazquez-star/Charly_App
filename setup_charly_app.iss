; Script de Inno Setup para Charly App v4.0
; Autor: Fernando Ramón Vázquez

#define MyAppName "Charly App"
#define MyAppVersion "4.0"
#define MyAppPublisher "Fernando Ramón Vázquez"
#define MyAppURL "https://github.com/fernandoramonvazquez-star/Charly_App"
#define MyAppExeName "Iniciar_Charly_App.bat"

[Setup]
AppId={{E1B95B72-9654-4D2A-B981-54D6C4B98E10}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={userappdata}\{#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=C:\Users\franv\OneDrive\Desktop
OutputBaseFilename=Instalador_Charly_App
SetupIconFile=C:\Users\franv\OneDrive\Desktop\Charly_App\peperina.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
; Archivos principales de la aplicación
Source: "C:\Users\franv\OneDrive\Desktop\Charly_App\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: ".git, .gitignore, __pycache__, Subir_a_GitHub.*, setup_charly_app.iss"

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\peperina.ico"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\peperina.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\Instalar_Charly_App.bat"; Description: "Configurar entorno de Python y dependencias (Recomendado para el primer uso)"; Flags: postinstall shellexec skipifsilent
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent unchecked
