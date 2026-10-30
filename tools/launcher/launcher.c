/* TokyoJungle.exe -- launcher with a settings screen (Windows, and SteamOS via Proton).
 *
 * Shows a small window to pick the resolution (1280x720 or 2560x1440) and
 * window/fullscreen, remembers the choice in launcher.ini, then does what
 * `scripts\launch_tokyojungle.ps1 -Run -Recommended` does without PowerShell:
 * sets the same environment, starts the recompiled game and waits for it (so
 * Steam sees the game as running until it closes).
 *
 * Folder layout, relative to this launcher:
 *   NPUA80523\                  extracted game (USRDIR, PARAM.SFO)
 *   engine\  or build\tokyojungle\
 *       tokyojungle.exe  or build-clang\tokyojungle.exe (+ ffmpeg.exe for movies)
 *       input\EBOOT.ELF, input\PARAM.SFO, controls.ini
 *   logs\                        created; stdout.log / stderr.log
 *   launcher.ini                 created; the saved choice
 *
 * Command line: -play starts with the saved choice without the window,
 * -2k forces 2560x1440, -fullscreen forces full screen. Holding Shift while
 * starting shows the window even when "don't ask again" was ticked.
 */
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <wchar.h>

#define MAXP 1024

enum { ID_RES_720 = 101, ID_RES_2K, ID_WINDOWED, ID_FULLSCREEN, ID_SKIP, ID_PLAY, ID_QUIT };

typedef struct {
    int two_k;       /* 0: 1280x720, 1: 2560x1440 */
    int fullscreen;  /* 0: window, 1: borderless full screen */
    int skip;        /* 1: start directly next time */
} Settings;

static wchar_t g_base[MAXP];
static wchar_t g_ini[MAXP];
static Settings g_settings;
static int g_play;
static HFONT g_font;

static int exists(const wchar_t* p) {
    return GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES;
}

static void join(wchar_t* out, const wchar_t* a, const wchar_t* b) {
    swprintf(out, MAXP, L"%ls\\%ls", a, b);
}

static int fail(const wchar_t* msg, const wchar_t* path) {
    wchar_t text[2 * MAXP];
    swprintf(text, 2 * MAXP, L"%ls\n\n%ls", msg, path ? path : L"");
    MessageBoxW(NULL, text, L"Tokyo Jungle", MB_OK | MB_ICONERROR);
    return 1;
}

static void load_settings(void) {
    g_settings.two_k = GetPrivateProfileIntW(L"video", L"resolution_2k", 0, g_ini) != 0;
    g_settings.fullscreen = GetPrivateProfileIntW(L"video", L"fullscreen", 0, g_ini) != 0;
    g_settings.skip = GetPrivateProfileIntW(L"launcher", L"dont_ask", 0, g_ini) != 0;
}

static void save_settings(void) {
    WritePrivateProfileStringW(L"video", L"resolution_2k", g_settings.two_k ? L"1" : L"0", g_ini);
    WritePrivateProfileStringW(L"video", L"fullscreen", g_settings.fullscreen ? L"1" : L"0", g_ini);
    WritePrivateProfileStringW(L"launcher", L"dont_ask", g_settings.skip ? L"1" : L"0", g_ini);
}

/* ---- settings window ---------------------------------------------------- */

static HWND add(HWND parent, const wchar_t* cls, const wchar_t* text, DWORD style,
                int x, int y, int w, int h, int id) {
    HWND c = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h,
                             parent, (HMENU)(INT_PTR)id, GetModuleHandleW(NULL), NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)g_font, TRUE);
    return c;
}

static LRESULT CALLBACK settings_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        add(hwnd, L"BUTTON", L"Resolução", BS_GROUPBOX, 12, 8, 316, 78, 0);
        add(hwnd, L"BUTTON", L"1280 x 720  (original do PS3, mais leve)",
            BS_AUTORADIOBUTTON | WS_GROUP | WS_TABSTOP, 24, 30, 296, 22, ID_RES_720);
        add(hwnd, L"BUTTON", L"2560 x 1440  (2K, mais nítido)",
            BS_AUTORADIOBUTTON, 24, 56, 296, 22, ID_RES_2K);
        add(hwnd, L"BUTTON", L"Tela", BS_GROUPBOX, 12, 94, 316, 78, 0);
        add(hwnd, L"BUTTON", L"Janela",
            BS_AUTORADIOBUTTON | WS_GROUP | WS_TABSTOP, 24, 116, 296, 22, ID_WINDOWED);
        add(hwnd, L"BUTTON", L"Tela cheia",
            BS_AUTORADIOBUTTON, 24, 142, 296, 22, ID_FULLSCREEN);
        add(hwnd, L"BUTTON", L"Não perguntar de novo (segure Shift ao abrir para mudar)",
            BS_AUTOCHECKBOX | WS_GROUP | WS_TABSTOP, 14, 180, 316, 22, ID_SKIP);
        add(hwnd, L"BUTTON", L"Jogar", BS_DEFPUSHBUTTON | WS_GROUP | WS_TABSTOP,
            146, 214, 88, 30, ID_PLAY);
        add(hwnd, L"BUTTON", L"Sair", BS_PUSHBUTTON | WS_TABSTOP, 240, 214, 88, 30, ID_QUIT);
        CheckRadioButton(hwnd, ID_RES_720, ID_RES_2K, g_settings.two_k ? ID_RES_2K : ID_RES_720);
        CheckRadioButton(hwnd, ID_WINDOWED, ID_FULLSCREEN,
                         g_settings.fullscreen ? ID_FULLSCREEN : ID_WINDOWED);
        CheckDlgButton(hwnd, ID_SKIP, g_settings.skip ? BST_CHECKED : BST_UNCHECKED);
        SetFocus(GetDlgItem(hwnd, ID_PLAY));
        return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wp) == ID_PLAY || LOWORD(wp) == IDOK) {
            g_settings.two_k = IsDlgButtonChecked(hwnd, ID_RES_2K) == BST_CHECKED;
            g_settings.fullscreen = IsDlgButtonChecked(hwnd, ID_FULLSCREEN) == BST_CHECKED;
            g_settings.skip = IsDlgButtonChecked(hwnd, ID_SKIP) == BST_CHECKED;
            g_play = 1;
            DestroyWindow(hwnd);
        } else if (LOWORD(wp) == ID_QUIT || LOWORD(wp) == IDCANCEL) {
            DestroyWindow(hwnd);
        }
        return 0;
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

/* Returns 1 to start the game, 0 if the player chose Sair. */
static int show_settings(HINSTANCE inst) {
    NONCLIENTMETRICSW ncm = { sizeof ncm };
    SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof ncm, &ncm, 0);
    g_font = CreateFontIndirectW(&ncm.lfMessageFont);

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = settings_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.hIcon = LoadIconW(NULL, IDI_APPLICATION);
    wc.lpszClassName = L"TokyoJungleLauncher";
    RegisterClassW(&wc);

    const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT r = {0, 0, 340, 256};
    AdjustWindowRect(&r, style, FALSE);
    const int w = r.right - r.left, h = r.bottom - r.top;
    HWND hwnd = CreateWindowW(wc.lpszClassName, L"Tokyo Jungle", style,
                              (GetSystemMetrics(SM_CXSCREEN) - w) / 2,
                              (GetSystemMetrics(SM_CYSCREEN) - h) / 2,
                              w, h, NULL, NULL, inst, NULL);
    ShowWindow(hwnd, SW_SHOW);
    SetForegroundWindow(hwnd);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (!IsDialogMessageW(hwnd, &msg)) {  /* Tab, Enter = Jogar, Esc = Sair */
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    DeleteObject(g_font);
    return g_play;
}

/* ---- game start ------------------------------------------------------------ */

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmdline, int show) {
    (void)prev; (void)show;

    wchar_t self[MAXP];
    GetModuleFileNameW(NULL, self, MAXP);
    wcscpy(g_base, self);
    wchar_t* slash = wcsrchr(g_base, L'\\');
    if (slash) *slash = 0;
    const wchar_t* selfname = slash ? slash + 1 : self;
    join(g_ini, g_base, L"launcher.ini");
    load_settings();

    const int arg_play = cmdline && wcsstr(cmdline, L"-play") != NULL;
    const int arg_2k = (cmdline && (wcsstr(cmdline, L"-2k") || wcsstr(cmdline, L"-2K"))) ||
                       wcsstr(selfname, L"2K") || wcsstr(selfname, L"2k");
    const int arg_full = cmdline && wcsstr(cmdline, L"-fullscreen") != NULL;
    const int shift = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;

    if (!arg_play && !arg_2k && !arg_full && (!g_settings.skip || shift)) {
        if (!show_settings(inst)) return 0;
        save_settings();
    }
    if (arg_2k) g_settings.two_k = 1;
    if (arg_full) g_settings.fullscreen = 1;

    /* Locate the engine folder and the recompiled executable. */
    wchar_t engine[MAXP], exe[MAXP], tmp[MAXP];
    const wchar_t* engine_dirs[] = { L"engine", L"build\\tokyojungle" };
    const wchar_t* exe_names[]   = { L"tokyojungle.exe", L"build-clang\\tokyojungle.exe" };
    int found = 0;
    for (int i = 0; i < 2 && !found; i++) {
        join(engine, g_base, engine_dirs[i]);
        for (int j = 0; j < 2 && !found; j++) {
            join(exe, engine, exe_names[j]);
            if (exists(exe)) found = 1;
        }
    }
    if (!found)
        return fail(L"Não encontrei o jogo (tokyojungle.exe) em engine\\ ou build\\tokyojungle\\ ao lado deste launcher.", g_base);

    join(tmp, engine, L"input\\EBOOT.ELF");
    if (!exists(tmp)) return fail(L"Falta o EBOOT.ELF descriptografado:", tmp);
    join(tmp, engine, L"input\\PARAM.SFO");
    if (!exists(tmp)) return fail(L"Falta o PARAM.SFO:", tmp);

    /* Game folder name: [paths] game= in launcher.ini (written by BUILD.bat),
     * NPUA80523 by default. */
    wchar_t game_dir[MAXP], game[MAXP];
    GetPrivateProfileStringW(L"paths", L"game", L"NPUA80523", game_dir, MAXP, g_ini);
    join(game, g_base, game_dir);
    join(tmp, game, L"USRDIR");
    if (!exists(tmp)) return fail(L"Falta a pasta do jogo extraído (NPUA80523 com USRDIR dentro):", game);

    wchar_t saves[MAXP], cache[MAXP], controls[MAXP], logs[MAXP], out_log[MAXP], err_log[MAXP];
    join(saves, engine, L"savedata");
    join(cache, engine, L"shader-cache");
    join(controls, engine, L"controls.ini");
    join(logs, g_base, L"logs");
    CreateDirectoryW(saves, NULL);
    CreateDirectoryW(cache, NULL);
    CreateDirectoryW(logs, NULL);
    join(out_log, logs, L"stdout.log");
    join(err_log, logs, L"stderr.log");

    /* Same environment as launch_tokyojungle.ps1 -Run -Recommended. */
    SetEnvironmentVariableW(L"PS3_VFS_ROOT", game);
    SetEnvironmentVariableW(L"PS3_HDD_GAME_ROOT", game);
    SetEnvironmentVariableW(L"PS3_VFS_READONLY", L"1");
    SetEnvironmentVariableW(L"PS3_TITLE", L"Tokyo Jungle");
    SetEnvironmentVariableW(L"PS3_SAVEDATA_ROOT", saves);
    SetEnvironmentVariableW(L"TJ_SHADER_CACHE_DIR", cache);
    SetEnvironmentVariableW(L"TJ_CONTROLS_FILE", controls);
    SetEnvironmentVariableW(L"TJ_STDOUT_FILE", out_log);
    SetEnvironmentVariableW(L"TJ_STDERR_FILE", err_log);

    static const wchar_t* recommended[][2] = {
        { L"TJ_AUDIO_BUFFER_MS", L"60" },       { L"TJ_AUDIO_MMCSS", L"1" },
        { L"TJ_BLIT_CLIP_ABSOLUTE", L"1" },     { L"TJ_BLIT_SNAPSHOT_POOL", L"1" },
        { L"TJ_DISABLE_MLAA", L"1" },           { L"TJ_EDGE_NOWAIT", L"1" },
        { L"TJ_FIFO_KICK_WAIT", L"1" },         { L"TJ_FLIP30_LIMIT", L"9" },
        { L"TJ_FLIP_PROMOTE", L"1" },           { L"TJ_FPS_TRACE", L"1" },
        { L"TJ_GCM_INTERRUPT_WORKER", L"1" },   { L"TJ_GPU_COMPLETION_REUSE", L"1" },
        { L"TJ_HIGH_QOS", L"1" },               { L"TJ_LABEL_EARLY_MEMO", L"1" },
        { L"TJ_LOOKUP_FASTPATH", L"1" },        { L"TJ_PREFIX_OVERLAP", L"1" },
        { L"TJ_PREFIX_OWNERSHIP", L"1" },       { L"TJ_PREFIX_QUEUED_PAIR", L"1" },
        { L"TJ_PREFIX_QUEUE_AHEAD", L"1" },     { L"TJ_PREFIX_REPLAY_PREPARE", L"1" },
        { L"TJ_SHADER_PREFETCH", L"1" },        { L"TJ_SNAPSHOT_LATE_PROOF", L"1" },
        { L"TJ_SPU_CTX_REUSE", L"1" },          { L"TJ_TEXTURE_LABEL_BATCH", L"1" },
        { L"TJ_TEXTURE_LABEL_CAP", L"32" },     { L"TJ_TEXTURE_LABEL_EARLY", L"3" },
        { L"TJ_TEXTURE_SNAPSHOT_HINT_RETARGET", L"1" },
        { L"TJ_TEXTURE_SNAPSHOT_RETAIN", L"1" },{ L"TJ_TEXTURE_WRITE_WATCH", L"1" },
        { L"TJ_VERTEX_PARALLEL", L"8" },        { L"TJ_VERTEX_PLAN", L"1" },
        { L"TJ_VP_UCODE_HASH_REUSE", L"1" },
    };
    for (size_t i = 0; i < sizeof recommended / sizeof recommended[0]; i++)
        SetEnvironmentVariableW(recommended[i][0], recommended[i][1]);

    if (g_settings.two_k) {
        SetEnvironmentVariableW(L"TJ_RENDER_SCALE", L"2");
        SetEnvironmentVariableW(L"TJ_VBLANK_SOURCE", L"display");
        SetEnvironmentVariableW(L"TJ_PRESENT_PHASE", L"1");
    }
    if (g_settings.fullscreen)
        SetEnvironmentVariableW(L"TJ_WINDOW_MODE", L"borderless");

    /* Start the game with the engine folder as working directory and wait. */
    wchar_t cmd[MAXP + 4];
    swprintf(cmd, MAXP + 4, L"\"%ls\"", exe);
    STARTUPINFOW si = { sizeof si };
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(exe, cmd, NULL, NULL, FALSE, 0, NULL, engine, &si, &pi))
        return fail(L"Não consegui iniciar o jogo:", exe);
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}
