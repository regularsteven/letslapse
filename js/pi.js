function openLink(url){
    window.open(url, "_blank");
}
function checkForm(){
    if(document.getElementById('live').checked === true){
        alert("Copy the following and paste to VLC");
        alert("tcp/h264://"+window.location.host+":3333");
        document.getElementById("mainForm").target = "_blank";
    }else{
        document.getElementById("mainForm").target = "";
    }
}


function toggleControls(value){
    document.getElementById("previewControls").style.display = value;
}


/* V.1 Release */ 


window.addEventListener("load", function(){
    console.log("document loaded");
    pollUptime();
    //streamManager("start");
    setPreset();
    parseProgress(true, true);
});



function log(msg){
    $("#systemLog").prepend(msg+"\n")
}

function power(resetOrOff){
    var confirmMessage = "";
    if(resetOrOff == "reset"){
        confirmMessage = "Reset LetsLapse? Restart will take a minute.";
    }else{
        confirmMessage = "Shutdown LetsLapse? Pysical power will need to be reconnected to turn on.";
    }

    var r = confirm(confirmMessage);
    if (r == true) {
        var apiCall = "/?action="+resetOrOff;
        streamManager("stop");
        $.getJSON( apiCall)
            .done(function( json ) {
               //this should be a response to indicate process is about to happen
               //alert("device about to " + resetOrOff);
               if(resetOrOff == "reset"){
                   displayStatus("isRestarting");
               }else{
                    displayStatus("isPowerOff");
               }
               $(".navbar-toggler").click();
            })
            .fail(function( jqxhr, textStatus, error ) {
                var err = textStatus + ", " + error;
                console.log( "Request Failed: " + err );
      });
    }
}

var presets = [];
presets["sunnyDay"] = {ss: 100, iso: 10, awbg: '1.76,2.1'};
presets["sunnyForrest"] = {ss: 5000, iso: 10, awbg: '3,2'};
presets["sunset"] = {ss: 20000, iso: 75, awbg: '3,2'};
presets["nightIndoor"] = {ss: 6 * 100000, iso: 800, awbg: '1.8,2.9'};
presets["nightUrban"] = {ss: 2 * 100000, iso: 800, awbg: '3,2'};
presets["nightNature"] = {ss: 6 * 100000, iso: 800, awbg: '3,2'};

function setPreset(){
    preset = $("#presets").val();
    document.getElementById('ss').value = presets[preset].ss;
    document.getElementById('iso').value = presets[preset].iso;
    document.getElementById('awbg').value = presets[preset].awbg;

    //clear the active filters
    var presetsList = document.getElementById("presets");
    var liTargets = presetsList.getElementsByTagName("li");
    for(var n=0; n<liTargets.length; n++ ){
        liTargets[n].className = "";
    }
}


function streamManager(startOrStop){
    if(startOrStop == "start"){
        displayStatus("isStreaming");
        $.getJSON( "/?action=startstreamer&cachebuster="+Math.random(100))
            .done(function( json ) {
                stream = ""
                if(window.location.host == "127.0.0.1"){ //for home testing
                    console.log("local testing, see if the device is on the network")
                    stream += "http://10.3.141.212:8081" //suspected IP of PiZero on home testing network via RaspAP
                }else{
                    stream += "http://"+window.location.host+":8081";
                }
                stream += "/stream.mjpg?cachebuster="+Math.random(100);
                displayStill(stream);
                })
            .fail(function( jqxhr, textStatus, error ) {
                var err = textStatus + ", " + error;
                alert("Issue with streaming - is it working?");
                displayStatus("isWarning");
                console.log( "Request Failed: " + err );
            });

    }else{
        window.stop();
        
        document.getElementById("imageViewport").style.backgroundImage = "none";
        $.getJSON( "/?action=killstreamer")
            .done(function( json ) {
                displayStatus("isReady");
            })
            .fail(function( jqxhr, textStatus, error ) {
                var err = textStatus + ", " + error;
                alert("Issue with stopping streaming");
                displayStatus("isWarning");
                console.log( "Request Failed: " + err );
            });
    }

}






function secondsToDhms(seconds) {
    var d = Math.floor(seconds / (3600*24));
    var h = Math.floor(seconds % (3600*24) / 3600);
    var m = Math.floor(seconds % 3600 / 60);
    var s = Math.floor(seconds % 60);
    
    var dDisplay = d > 0 ? d + (d == 1 ? " day, " : " days, ") : "";
    var hDisplay = h + ":";
    var mDisplay = m+":";
    if (m < 10){
        mDisplay = "0"+m+":"
    }
    var sDisplay = s;
    if (s < 10){
        sDisplay = "0"+s;
    }

    return dDisplay + hDisplay + mDisplay + sDisplay;
    }


var realUptimeIndex=0;
var realUptimeCheckEvery=59;
var realUptimeLatest=-1;
function pollUptime(){
    //console.log("pollUptime: "+ realUptimeIndex);

    realUptimeIndex++;
    if (realUptimeIndex == 1){
        console.log("pollUptime REAL");
        $.getJSON( "/?action=uptime")
            .done(function( json ) {
                //console.log( Number(json.seconds));
                realUptimeLatest = json.seconds;
                $("footer").html("Running "+ secondsToDhms(realUptimeLatest));
                log("Uptime Seconds: "+realUptimeLatest+"\n");
                if(currentStatus == "isRestarting"){ //we're basically checking to see if the divice has come back to life
                    displayStatus("isReady");
                    parseProgress(true, true);
                }

                window.setTimeout(pollUptime, 1000);
            })
            .fail(function( jqxhr, textStatus, error ) {
                var err = textStatus + ", " + error;
                if(currentStatus == "isRestarting"){
                    console.log("Device in restart state, need to check again")
                    realUptimeIndex = -10; //this will force a poll in 10 seconds
                    $("footer").html("Device currently restarting, checking again in " + (0 - realUptimeIndex));
                    
                    window.setTimeout(pollUptime, 1000);
                }else{
                    alert("Issue with camera - is it working?");
                }
                console.log( "Request Failed: " + err );
      });
    
    }else{
        //console.log("pollUptime fake");
        realUptimeLatest++
        if(currentStatus == "isRestarting"){
            if(realUptimeIndex > 1){
                realUptimeIndex = -10;
            }
            $("footer").html("Device currently restarting, checking again in " + (0 - realUptimeIndex));            
        }else{
            $("footer").html("Running "+ secondsToDhms(realUptimeLatest));
        }
        if (realUptimeIndex > realUptimeCheckEvery){
            realUptimeIndex = 0;
        }
        window.setTimeout(pollUptime, 1000);
    }
}


function clickViewport(){
    if(currentStatus == "isShooting"){
        parseProgress(true, false);
    }else if(currentStatus == "isReady"){
        //if(document.getElementById("imageViewport").style.backgroundImage == "none"){
        streamManager("start");
        //}
    }else if(currentStatus == "isStreaming"){
        streamManager("stop");
    }
}

function takeStill(){
    var apiCall = "?action=preview";

    if($("#manualSwitch1").is(":checked")){
        //shotting in auto mode
        apiCall += "&mode=auto";
    }else{
        apiCall += "&mode=manual&ss="+$("#ss").val()+"&iso="+$("#iso").val()+"&awbg="+$("#awbg").val();
    }

    displayStatus("isShooting");

    streamManager("stop");
    $.getJSON( apiCall)
        .done(function( json ) {
            console.log( "JSON Data: " + json );
            displayStill("/previews/"+json.filename);
            displayStatus("isReady");
            //window.setTimeout('streamManager("start");console.log("1 second attempt");', 1000);
            //window.setTimeout('streamManager("start");console.log("3 second attempt");', 3000);
            //window.setTimeout('streamManager("start");console.log("6 second attempt");', 6000);
        })
        .fail(function( jqxhr, textStatus, error ) {
            var err = textStatus + ", " + error;
            console.log( "Request Failed: " + err );
  });
}

var progressTxt = null;
function parseProgress(displayLatest, execOnStartup){
    jQuery.get('progress.txt', function(data) {
        console.log("data start");
        if (data == ""){
            console.log("no progress.txt in place, indicating this is brand new");
        }else{
            progressTxt = (data).split("\n");
            var progressIndex = parseInt(progressTxt[0]);
            var progressName = progressTxt[1];
            //put the current shoot name inside the input box
            $("#shootName").val(progressName);
            var folderNum = Math.ceil((progressIndex+1)/1000)-1
            var latestImage = "/auto_"+progressName+"/group"+folderNum+"/image"+progressIndex+".jpg";
            
            if (displayLatest){
                console.log(latestImage);
                displayStill(latestImage);
            }
            $("#status .isShooting .extraInfo").html(" | Images: "+  progressTxt[0]);

            if(execOnStartup){
                startTimelapseDelay();
            }

        }
    });
}


function timelapseMode(startOrStop){
    if (startOrStop == "start"){
        displayStatus("isShooting");
        $("#photo-tab").addClass("disabled");
        $("#timelapse .custom-switch").addClass("d-none");
        
        $("#timelapse .startBtn").addClass("d-none");
        $("#timelapse .stopBtn").removeClass("d-none");

        $("#timelapse .pauseOrKillContainer").removeClass("d-none"); 

        parseProgress(true, false);
    }else{
        displayStatus("isReady");
        $("#photo-tab").removeClass("disabled");
        $("#timelapse .custom-switch").removeClass("d-none");
        
        $("#timelapse .startBtn").removeClass("d-none");
        $("#timelapse .stopBtn").addClass("d-none");

        
        $("#timelapse .pauseOrKillContainer").addClass("d-none"); 
    }
    
}


function stopTimelapse(){
    var txt;
    var r = confirm("Stop timelapse shoot?");
    if (r == true) {
        console.log("You pressed OK!");
        var apiCall = "?action=killtimelapse";
        if($("#pauseOrKill").is(':checked')){
            apiCall += "&pauseOrKill=kill";
            $("#pauseOrKill").click();
        }else{
            apiCall += "&pauseOrKill=pause";
        }


        $.getJSON( apiCall)
            .done(function( json ) {
                console.log(json );
                //alert("Timelapse in action. This is time consuming and heavy on the system. Doing too much, the system will crash.");
                //displayStill("latest.jpg");
                progressTxt = null;
                timelapseMode("stop");
                //window.setTimeout('streamManager("start");console.log("1 second attempt");', 1000);
                //window.setTimeout('streamManager("start");console.log("3 second attempt");', 3000);
                //window.setTimeout('streamManager("start");console.log("6 second attempt");', 6000);
            })
            .fail(function( jqxhr, textStatus, error ) {
                var err = textStatus + ", " + error;
                console.log( "Request Failed: " + err );
            });
    } else {
        console.log("You pressed Cancel!");
    }
}

function startTimelapse(){
    streamManager("stop");
    window.setTimeout("startTimelapseDelay()", 1000);
}

function startTimelapseDelay(){
    var apiCall = "?action=timelapse";
    var shootName = "default";
    if($("#manualSwitch2").is(":checked")){
        apiCall += "&mode=manual"; //&ss="+$("#ss").val()+"&iso="+$("#iso").val()+"&awbg="+$("#awbg").val();
        if ($("#shootName").val() !== ""){
            shootName = $("#shootName").val();
        }
    }else{
        //shotting in auto mode
        
        apiCall += "&mode=auto";
    }
    apiCall += "&shootName="+shootName;
    $.getJSON( apiCall)
    .done(function( json ) {
        console.log( json );
        log("timelapse: "+json.shootName + " - " + json.message);
        
        if(json.error){
            console.log("focus on input, show the manual controls")
            $("#manualSwitch2").click();
            $("#shootName").focus();
        }else{
            timelapseMode("start");
        }
        
    })
    .fail(function( jqxhr, textStatus, error ) {
        var err = textStatus + ", " + error;
        console.log( "Request Failed: " + err );
    });
}



function displayStill(filename){

    var capturedImage = filename;
    //ideally check the image is there, to work around the issue for streaming not being ready yet - but CORS is an issue, so don't bother... 
    /*$.ajax({
        url: filename,
        error: function() 
        {
            console.log("file is not good");
        },
        success: function() 
        {
            console.log("file is good");
            
        }
    });
    */
    document.getElementById("imageViewport").style.backgroundImage = "url('"+capturedImage+"')";
}

function updateCode(){
    apiCall = "?action=updatecode";
    $.getJSON( apiCall)
    .done(function( json ) {
        console.log( "JSON Data: " + json );
        //alert("Timelapse in action. This is time consuming and heavy on the system. Doing too much, the system will crash.");
        //displayStill("latest.jpg");
        log("Update Code: "+ json.updateCodeResp)
        //window.setTimeout('streamManager("start");console.log("1 second attempt");', 1000);
        //window.setTimeout('streamManager("start");console.log("3 second attempt");', 3000);
        //window.setTimeout('streamManager("start");console.log("6 second attempt");', 6000);
    })
    .fail(function( jqxhr, textStatus, error ) {
        var err = textStatus + ", " + error;
        console.log( "Request Failed: " + err );
        log("Update Code ERROR: "+ error)
    });
}

var currentStatus = "isReady";
function displayStatus(which){
    currentStatus = which;
    $("#status .statusMessage").addClass("d-none");
    $("#status ."+which).removeClass("d-none");
}