<?php 
$outputHTML = "";
$killswitch = false;
if(isset($_REQUEST['action'])){
    
    $action = $_REQUEST['action'];
    switch ($action) {
        case "preview":
            echo "preview image: ";
            //ob_start();
            //passthru("python3 preview.py");
            //$output = ob_get_clean(); 
            $command = "python3 preview.py ".$_REQUEST['ss'] . " ".$_REQUEST['iso'];
            $resp = shell_exec($command); 
            $outputHTML = "<img src='$resp' />";
            break;
        case "start":
            echo "action switch";
            shell_exec("python3 timelapse.py"); 
            break;
        case "live":
            $resp = shell_exec("python3 live.py"); 
            echo "<button onclick='window.close()'>Close Me</button>";
            $killswitch = true;
            break;
    }
}


if($killswitch == true){
    die();
}
?>
<h1><a href="/">PiPic</a></h1>

<script>

    function openLink(url){
        window.open(url, "_blank");
    }
    function checkForm(){
        if(document.getElementById('live').checked === true){
            alert("Copy the following and paste to VLC");
            alert("tcp/h264://192.168.30.76:3333");
            document.getElementById("mainForm").target = "_blank";
        }else{
            document.getElementById("mainForm").target = "";
        }
    }

</script>

<?php echo $outputHTML ; ?>

<form action="/" target="" id="mainForm">
<h2>Actions</h2>

<input type="radio" id="live" name="action" value="live">
<label for="live">Live Preview</label><br>
<input checked type="radio" id="preview" name="action" value="preview">
<label for="preview">Preview Image</label><br>
<input type="radio" id="start" name="action" value="start">
<label for="start">Start Timelapse</label>
<br />
<br />
Shutter Speed - Seconds (or .5 for half) </br>
<input value="1" name="ss"></input>
<br /><br />
ISO
<select id="iso" name="iso">
  <option>100</option>
  <option>200</option>
  <option>400</option>
  <option>800</option>
</select>
<br /><br />

<button type="submit" onclick="checkForm()">GO</button>
</form>


