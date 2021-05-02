<?php 
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
<style>
html {
    margin: 0;
    padding: 0;
    border: 0;
}

body{
    font-family: "Trebuchet MS", Helvetica, sans-serif;
}
ul{
    padding-left: 0;
    text-align: center;
    display: flex;
    margin-left: -10px;
}

ul#presets li {

    height: 80px;
    border: 2px solid lightgray;
    margin: 1.5%;
    text-align: center;
    display: inline-table;
    list-style: none;
    font-size: small;
}

ul#presets li.active{
    border: 2px solid darkgreen;
    color: darkgreen;
    background-color: lightgrey;
}

#mainForm{
    clear:both;
}

.splitCol {
    width: 50%;
    float: left;
}


button{
    width: 100%;
    padding: 10px;
    font-size: larger;
    margin-top: 20px;
}
.splitCol select{
    width: 100%;
    padding: 10px;
    font-size: larger;
}
.splitCol input {
    width: 80%;
    padding: 10px;
    font-size: larger;
}
img {
    max-width: 100%;
}


#previewControls{
    display:none;
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
    
    

    $ss = $_REQUEST['ss'];
    $iso = $_REQUEST['iso'];

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
            $resp = shell_exec("python3 live.py"); 
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

    var presets = [];
    presets["sunnyDay"] = {ss: .002, iso: 100};
    presets["sunnyForrest"] = {ss: .05, iso: 100};
    presets["sunset"] = {ss: 1, iso: 100};
    presets["lastLight"] = {ss: 6, iso: 200};
    presets["nightUrban"] = {ss: 10, iso: 400};
    presets["nightNature"] = {ss: 30, iso: 400};

    function setPreset(preset){
        document.getElementById('ss').value = presets[preset].ss;
        document.getElementById('iso').value = presets[preset].iso;

        //clear the active filters
        var presetsList = document.getElementById("presets");
        var liTargets = presetsList.getElementsByTagName("li");
        for(var n=0; n<liTargets.length; n++ ){
            liTargets[n].className = "";
        }

        //add the active
        var v = document.getElementById(preset);
            v.className += "active";

    }

    function toggleControls(value){
        document.getElementById("previewControls").style.display = value;
    }

</script>

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

</div> <!--  id="previewControls"-->

<button type="submit" onclick="checkForm()">GO</button>
</form>


</body>
</html>