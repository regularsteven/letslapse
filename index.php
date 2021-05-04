<?php 
$isPreview = "";
        if(isset($_REQUEST['action'])){
            $action = $_REQUEST['action'];
            if($action == "preview"){
                $isPreview = true;
            }
        }
    ?>
<!DOCTYPE html>
<html>
<head>
<title>PiPic</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="css/pi.css">
<style>
#previewControls{
    <?php if($isPreview){echo "display:block;";} ?>
}
</style>

<?php 
$outputHTML = "";
$killswitch = false;

//defaults for no previous settings
$ss = ".5";
$iso = "100";


if(isset($_REQUEST['action'])){
    $ss = $_REQUEST['ss'];$iso = $_REQUEST['iso'];

    switch ($action) {
        case "preview":
            $command = "python3 preview.py ".$_REQUEST['ss'] . " ".$_REQUEST['iso'];
            $resp = shell_exec($command); 
            $outputHTML = "<a href='?action=raw&rawPath=$resp' target='_blank'><img src='$resp' /><sub>Generate RAW</sub></a>";
            break;
        case "start":
            shell_exec("python3 timelapse.py"); 
            break;
        case "live":
            $cmd = "python3 live.py " . $_SERVER['HTTP_HOST'];
            $resp = shell_exec($cmd); 
            echo "<button onclick='window.close()'>Close Me</button>";
            $killswitch = true;
            break;
        case "raw":
            $fileForProcess = explode("/", $_REQUEST['rawPath']);
            $resp = shell_exec("/usr/bin/python3 createRAW.py " . $fileForProcess[2] );
            echo "<a href='/previews'>See converted</a><button onclick='window.close()'>DONE Me</button>";
            $killswitch = true;
            break;
    }
}

if($killswitch == true){
    die();
}

?>

</head>
<body>


<h1><a href="/">PiPic</a></h1>

<script src="js/pi.js"></script>

<?php echo $outputHTML ; ?>

<form action="/" target="" id="mainForm">
<h3>Actions</h3>

<input onclick="toggleControls('none')" type="radio" id="live" name="action" value="live">
<label for="live">Feed</label>
<input onclick="toggleControls('block')" <?php if($isPreview){echo "checked";} ?> type="radio" id="preview" name="action" value="preview">
<label for="preview">Photo</label>
<input onclick="toggleControls('none')" type="radio" id="start" name="action" value="start">
<label for="start">Timelapse</label>
<br />
<script>
document.write("tcp/h264://"+window.location.host+":3333");
</script>


<div id="previewControls">
<h3>Presets</h3>
<i>5 stops from open</i>
<ul id="presets">
    <li onclick="setPreset('sunnyDay');" id="sunnyDay">Sunny Day Open Sky</li>
    <li onclick="setPreset('sunnyForrest');" id="sunnyForrest">Sunny Day Covered Forrest</li>
    <li onclick="setPreset('sunset');" id="sunset">Sunset</li>
    <li onclick="setPreset('lastLight');" id="lastLight">Last Light</li>
    <li onclick="setPreset('nightUrban');" id="nightUrban">Urban Night</li>
    <li onclick="setPreset('nightNature');" id="nightNature">Nature at Night</li>
</ul>


<div class="splitCol">
<h4>Shutter Speed</h4>
<input id="ss" value="<?php echo $ss ?>" name="ss"></input>
</div>
<div class="splitCol">
<h4>ISO</h4>
<select id="iso" name="iso">
  <option <?php if($iso == "100"){echo "selected";} ?>>100</option>
  <option <?php if($iso == "200"){echo "selected";} ?>>200</option>
  <option <?php if($iso == "400"){echo "selected";} ?>>400</option>
  <option <?php if($iso == "800"){echo "selected";} ?>>800</option>
</select>
</div>
<div class="newRow">
<input type="checkbox" name="captureRaw" id="captureRaw" ></input><label for="captureRaw">Capture RAW image</label>
</div>
</div> <!--  id="previewControls"-->

<button type="submit" onclick="checkForm()">GO</button>
</form>


</body>
</html>
