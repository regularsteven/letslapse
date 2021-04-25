<?php 
echo "PHP working";

if(isset($_REQUEST['action'])){
    
    $action = $_REQUEST['action'];
    switch ($action) {
        case "preview":
            echo "preview switch";
            $resp = shell_exec("./preview.py");
        
            $respArr = explode("\n", $resp);
        
            echo (json_encode($respArr));
            break;
        case "action":
            echo "action switch";
            break;
    }


 
}
?>
<a href="?action=preview">Preview</a>
<br />
