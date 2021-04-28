<?php 
echo "<h1>PiPic</h1>";

if(isset($_REQUEST['action'])){
    
    $action = $_REQUEST['action'];
    switch ($action) {
        case "preview":
            echo "preview switch";
            $resp = shell_exec("python3 preview.py");
        
            //$respArr = explode("\n", $resp);
        
            echo "<a href='$resp'>image</a><hr>";
            break;
        case "start":
            echo "action switch";
            shell_exec("python3 timelapse.py"); 
            break;
    }

}
?>
<a href="?action=preview">New Preview</a>
<br />
<a href="?action=start">Start Timelapse</a>
