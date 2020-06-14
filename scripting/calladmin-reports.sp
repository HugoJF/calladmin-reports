#include <sourcemod>
#include <calladmin>
#include <SteamWorks>
#include <json>

#define PLUGIN_VERSION "1.0"
#define MAX_JSON_STRING_SIZE 4096
#define DEMO_UPLOAD_DELAY 5.0

/*
    - Atualizar o Calladmin para gerar os links pra enviar a demo;
    - Evitar usar CreateTimer(CreateTimer()), criar os dois ao mesmo tempo
    - Usar template de criacao de Report
    - Verificar todos os possiveis erros do SteamWorks
    - padronizar cvars
    - adicionar mensagens para todos do servidor quando a demo esta sendo gravada
    - evitar pegar request quando ele passa do tamnaho do buffer
    - bibliotecas pra JSON?
    - md5 pelo header? https://forums.alliedmods.net/showthread.php?t=145883
    - validar .dem ?
*/

char g_sHostPort[6];
char g_sServerName[256];
char g_sHostIP[16];

ConVar g_cWebHook;
ConVar g_cRecordDuration;
ConVar g_cDemoPath;

bool g_bIsTVRecording = false;

char g_sCurrentReportId[64];
char g_sCurrentDemoPath[PLATFORM_MAX_PATH];
char g_sCurrentDemoFilename[PLATFORM_MAX_PATH];
char g_sDemoPostUrl[512];

public Plugin myinfo = 
{
    name = "CallAdmin Reports",
    author = "de_nerd",
    description = "",
    version = PLUGIN_VERSION,
    url = "denerdtv.com"
}

public void OnPluginStart()
{
    CreateConVar("calladmin_reports", PLUGIN_VERSION, "CallAdmin Middleware version", FCVAR_DONTRECORD|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
    
    g_cWebHook = CreateConVar("calladmin_reports_webhook", "http://calladmin-middleware.denerdtv.com", "URL to send report information");
    g_cRecordDuration = CreateConVar("sm_rdr_recordtime", "15", "Time in seconds to stop recording automatically (0 = Disable [default])");
    g_cDemoPath = CreateConVar("sm_cr_demo_path", "demos", "Path to store recorded demos by CallAdmin (let . to upload demos to the cstrike/csgo folder)");

    RegServerCmd("sm_cr_test", Command_Test, "Fakes a report");

    AutoExecConfig(true, "calladmin_reports");
}

public void OnAllPluginsLoaded()
{
    if (!LibraryExists("calladmin")) {
        SetFailState("CallAdmin not found");
        return;
    }
    
    UpdateAddress();

    CallAdmin_GetHostName(g_sServerName, sizeof(g_sServerName));
}

public void CallAdmin_OnRequestTrackersCountRefresh(int &trackers)
{
    trackers++;
    PrintToServer("Base plugin requested a tracker count from us");
}

void UpdateAddress()
{
    GetConVarString(FindConVar("hostport"), g_sHostPort, sizeof(g_sHostPort));
    
    if (FindConVar("net_public_adr") != null)  {
        GetConVarString(FindConVar("net_public_adr"), g_sHostIP, sizeof(g_sHostIP));
    }
    
    if (strlen(g_sHostIP) == 0 && FindConVar("ip") != null) {
        GetConVarString(FindConVar("ip"), g_sHostIP, sizeof(g_sHostIP));
    }
    
    if (strlen(g_sHostIP) == 0 && FindConVar("hostip") != null) {
        int ip = GetConVarInt(FindConVar("hostip"));
        FormatEx(g_sHostIP, sizeof(g_sHostIP), "%d.%d.%d.%d", (ip >> 24) & 0x000000FF, (ip >> 16) & 0x000000FF, (ip >> 8) & 0x000000FF, ip & 0x000000FF);
    }
}

// https://github.com/nanociaglia/ReportDemoRecorder
public void CallAdmin_OnServerDataChanged(ConVar convar, ServerData type, const char[] oldVal, const char[] newVal)
{
    if (type == ServerData_HostName) {
        CallAdmin_GetHostName(g_sServerName, sizeof(g_sServerName));
    }
}

public Action Command_Test(int args)
{
    JSON_Object hBody = new JSON_Object();

    hBody.SetString("reason", "report de teste");

    hBody.SetString("reporter_name", "de_nerd");
    hBody.SetString("reporter_id", "STEAM_0:1:36509127");

    hBody.SetString("target_name", "cs_denerd");
    hBody.SetString("target_id", "STEAM_0:1:36509128");
    
    hBody.SetString("hostname", g_sServerName);

    hBody.SetBool("vip", true);

    hBody.SetString("server_ip", g_sHostIP);
    hBody.SetString("server_port", g_sHostPort);

    GenerateReport(hBody);
}

public void CallAdmin_OnReportPost(int client, int target, const char[] reason)
{
    // TODO: check player count to avoid weird shit
    PrintToServer("CallAdmin_OnReportPost() triggered");

    JSON_Object hBody = new JSON_Object();

    hBody.SetString("reason", reason);

    if (client == REPORTER_CONSOLE) {
        hBody.SetString("reporter_name", "Server");
        hBody.SetString("reporter_id", "CONSOLE");
    } else {
        char clientAuth[21];
        char clientName[MAX_NAME_LENGTH];

        GetClientAuthId(client, AuthId_Steam2, clientAuth, sizeof(clientAuth));
        GetClientName(client, clientName, sizeof(clientName));

        hBody.SetString("reporter_name", clientName);
        hBody.SetString("reporter_id", clientAuth);
    }
    
    // Target information
    char targetAuth[21];
    char targetName[MAX_NAME_LENGTH];
    GetClientAuthId(target, AuthId_Steam2, targetAuth, sizeof(targetAuth));
    GetClientName(target, targetName, sizeof(targetName));

    hBody.SetString("target_name", targetName);
    hBody.SetString("target_id", targetAuth);
    
    hBody.SetString("hostname", g_sServerName);

    // Replace placeholders
    if (GetUserFlagBits(client) & (ADMFLAG_RESERVATION) == (ADMFLAG_RESERVATION)) {
        hBody.SetBool("vip", true);
    } else {
        hBody.SetBool("vip", false);
    }

    hBody.SetString("server_ip", g_sHostIP);
    hBody.SetString("server_port", g_sHostPort);

    GenerateReport(hBody);
}

void GenerateReport(JSON_Object hBody)
{
    char sWebHook[256];
    g_cWebHook.GetString(sWebHook, sizeof(sWebHook));

    LogMessage("Generating response by POST requesting: %s", sWebHook);

    char sRequestBody[MAX_JSON_STRING_SIZE];

    hBody.Encode(sRequestBody, sizeof(sRequestBody));

    json_cleanup_and_delete(hBody);

    Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, sWebHook);

    SteamWorks_SetHTTPCallbacks(hRequest, ReportCreationRequestCallback);
    SteamWorks_SetHTTPRequestRawPostBody(hRequest, "application/json", sRequestBody, strlen(sRequestBody));

    SteamWorks_SendHTTPRequest(hRequest);
}

void ReportCreationRequestCallback(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode)
{
    if (bFailure) {
        LogError("[ReportCreationRequestCallback()] Request failure");

        return;
    }

    if (eStatusCode != k_EHTTPStatusCode200OK && eStatusCode != k_EHTTPStatusCode201Created) {
        LogError("[ReportCreationRequestCallback] Request returned status code: %d", eStatusCode);

        return;
    }

    int iResponseSize;
    SteamWorks_GetHTTPResponseBodySize(hRequest, iResponseSize);

    LogMessage("Response size: %d bytes", iResponseSize);

    if (iResponseSize >= MAX_JSON_STRING_SIZE) {
        LogError("[ReportCreationRequestCallback()] API response is bigger than buffer %d >= %d", iResponseSize, MAX_JSON_STRING_SIZE);

        return;
    }

    // Building JSON Object from API response
    char sResponse[MAX_JSON_STRING_SIZE];
    SteamWorks_GetHTTPResponseBodyData(hRequest, sResponse, iResponseSize);

    JSON_Object hResponse = json_decode(sResponse);

    if (hResponse == INVALID_HANDLE) {
        LogError("Invalid handle from json_decode");
        LogError("%s", sResponse);

        return;
    }

    // Set globals of current report
    int iId = hResponse.GetInt("id");

    IntToString(iId, g_sCurrentReportId, sizeof(g_sCurrentReportId));
    hResponse.GetString("demo_url", g_sDemoPostUrl, sizeof(g_sDemoPostUrl));

    PrintToServer("INFO: Report generated with ID %s and demo URL: %s", g_sCurrentReportId, g_sDemoPostUrl);
    LogMessage("INFO: Report generated with ID %s and demo URL: %s", g_sCurrentReportId, g_sDemoPostUrl);

    StartRecordingDemo();
}

// https://github.com/nanociaglia/ReportDemoRecorder
void StartRecordingDemo()
{
    if (g_cRecordDuration.FloatValue < 5) {
        LogError("Record duration is too low");

        return;
    }

    if (g_cRecordDuration.FloatValue > 60) {
        LogError("Record duration is too high");

        return;
    }

    float fDuration = g_cRecordDuration.FloatValue;
    PrintToServer("Starting demo recording for %f seconds", fDuration);
    LogMessage("Starting demo recording for %f seconds", fDuration);

    char sBasePath[PLATFORM_MAX_PATH];
    g_cDemoPath.GetString(sBasePath, sizeof(sBasePath));

    Format(g_sCurrentDemoFilename, sizeof(g_sCurrentDemoFilename), "%s.dem", g_sCurrentReportId);
    Format(g_sCurrentDemoPath, sizeof(g_sCurrentDemoPath), "%s/%s", sBasePath, g_sCurrentDemoFilename);

    char sRecordCommand[PLATFORM_MAX_PATH];
    Format(sRecordCommand, sizeof(sRecordCommand), "%s/%s", sBasePath, g_sCurrentReportId);

    PrintToServer("Issued command to record demo: %s", sRecordCommand);

    ServerCommand("tv_record \"%s\"", sRecordCommand);

    g_bIsTVRecording = true;

    Handle timer = CreateTimer(fDuration, Timer_StopRecord);

    if (timer == INVALID_HANDLE) {
        LogError("[StartRecordingDemo()] Could not setup timer to stop recording");

        return;
    }
}

public Action Timer_StopRecord(Handle timer)
{
    StopRecordDemo();

    // TODO: wait for demo flush
    CreateTimer(DEMO_UPLOAD_DELAY, Timer_UploadDemo);
}

// https://github.com/nanociaglia/ReportDemoRecorder
void StopRecordDemo()
{
    if (g_bIsTVRecording) {
        PrintToServer("Stopping GOTV demo recording...");
        ServerCommand("tv_stoprecord");
    } else {
        PrintToServer("StopRecordDemo() was called but not demo is being recorded!");
        LogMessage("StopRecordDemo() was called but not demo is being recorded!");
    }
}


public Action Timer_UploadDemo(Handle timer)
{
    UploadDemo(g_sCurrentDemoPath);
}

void UploadDemo(char[] sPath)
{
    PrintToServer("[UploadDemo()] Uploading %s to %s", sPath, g_sDemoPostUrl);
    LogError("[UploadDemo()] Uploading %s to %s", sPath, g_sDemoPostUrl);

    Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, g_sDemoPostUrl);
    bool bBodySet = SteamWorks_SetHTTPRequestRawPostBodyFromFile(hRequest, "application/x-binary", sPath);

    if (!bBodySet) {
        LogError("[UploadDemo()] Failed to set request body. Path: %s", sPath);

        return;
    }

    SteamWorks_SetHTTPCallbacks(hRequest, UploadCallback);
    SteamWorks_SendHTTPRequest(hRequest);
}

void UploadCallback(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode)
{
    if (bFailure) {
        LogError("[UploadCallback()] Upload failure");

        return;
    }

    if (eStatusCode != k_EHTTPStatusCode200OK && eStatusCode != k_EHTTPStatusCode201Created) {
        LogError("[UploadCallback()] Request returned status code: %d", eStatusCode);

        return;
    }

    int iResponseSize;
    SteamWorks_GetHTTPResponseBodySize(hRequest, iResponseSize);

    PrintToServer("Response size: %d", iResponseSize);
    LogMessage("Response size: %d", iResponseSize);

    if (iResponseSize >= MAX_JSON_STRING_SIZE) {
        LogError("[UploadCallback()] API response is bigger than buffer %d >= %d", iResponseSize, MAX_JSON_STRING_SIZE);

        return;
    }

    char sResponse[MAX_JSON_STRING_SIZE];
    SteamWorks_GetHTTPResponseBodyData(hRequest, sResponse, iResponseSize);

    LogMessage("Upload response %s", sResponse);

    VariableCleanup();
}

void VariableCleanup()
{
    g_bIsTVRecording = false;
}

void InitDirectory(const char[] sDir)
{
    char sPieces[32][PLATFORM_MAX_PATH];
    char sPath[PLATFORM_MAX_PATH];
    int iNumPieces = ExplodeString(sDir, "/", sPieces, sizeof(sPieces), sizeof(sPieces[]));

    for (int i = 0; i < iNumPieces; i++) {
        Format(sPath, sizeof(sPath), "%s/%s", sPath, sPieces[i]);
        if (!DirExists(sPath)) {
            CreateDirectory(sPath, 509);
        }
    }
}