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

var currentStatus = "isLoading";

window.addEventListener("load", function(){
    console.log("document loaded");
    pollUptime();
    //streamManager("start");
    setPreset();
    parseProgress(true, true);
    forceCharacterValidationOnInput();
    //stop clicks from passing through links:
    $("#messageViewport a").click(function(e) {
        e.preventDefault();
      });
});


function forceCharacterValidationOnInput(){
    $('input.shootName').on('keypress', function (event) {
        var regex = new RegExp("^[a-zA-Z0-9]+$");
        var key = String.fromCharCode(!event.charCode ? event.which : event.charCode);
        if (!regex.test(key)) {
           event.preventDefault();
           return false;
        }
    });
}

function log(msg){
    $("#systemLog").prepend(msg+"\n")
}
function validateInput(e) {
	var keyCode = e.keyCode || e.which;
	var errorMsg = document.getElementById("lblErrorMsg");
	errorMsg.innerHTML = "";

	//Regex to allow only Alphabets Numbers Dash Underscore and Space
	var pattern = /^[a-z\d\-_\s]+$/i;

	//Validating the textBox value against our regex pattern.
	var isValid = pattern.test(String.fromCharCode(keyCode));
	if (!isValid) {
		errorMsg.innerHTML = "Invalid Attempt, only alphanumeric, dash , underscore and space are allowed.";
	}

	return isValid;
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
                //alert("Issue with streaming - is it working?");
                displayStatus("isWarning");
                console.log( "Request Failed: " + err );
            });

    }else{
        window.stop();
        
        document.getElementById("imageViewport").style.backgroundImage = "url(/img/square-logo-bw-trans.png)";
        $.getJSON( "/?action=killstreamer")
            .done(function( json ) {
                displayStatus("isReady");
            })
            .fail(function( jqxhr, textStatus, error ) {
                var err = textStatus + ", " + error;
                //alert("Issue with stopping streaming");
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
var hostName = null;
function pollUptime(){
    //console.log("pollUptime: "+ realUptimeIndex);

    realUptimeIndex++;
    if (realUptimeIndex == 1){
        console.log("pollUptime REAL");
        $.getJSON( "/?action=uptime")
            .done(function( json ) {
                //console.log( Number(json.seconds));
                realUptimeLatest = json.seconds;
                hostName = json.hostname;
                $("footer").html(hostName +" up "+ secondsToDhms(realUptimeLatest));
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
                    $("footer").html(hostName+" currently restarting, checking again in " + (0 - realUptimeIndex));
                    
                    window.setTimeout(pollUptime, 1000);
                }else{
                    alert("Issue with uptime poll - is camera working?");
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
            $("footer").html(hostName+" currently restarting, checking again in " + (0 - realUptimeIndex));            
        }else{
            $("footer").html(hostName+" up "+ secondsToDhms(realUptimeLatest));
        }
        if (realUptimeIndex > realUptimeCheckEvery){
            realUptimeIndex = 0;
        }
        window.setTimeout(pollUptime, 1000);
    }
}


function clickViewport(){
    if(currentStatus == "isLoading")return false;

    if(currentStatus == "isShootingTimelapse"){
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
        apiCall += "&mode=manual&ss="+$("#ss").val()+"&iso="+$("#iso").val()+"&awbg="+$("#awbg").val()+"&raw="+$("#captureRaw").is(":checked");
    }else{
        //shotting in auto mode
        apiCall += "&mode=auto";
    }

    
    displayStatus("isShooting");

    streamManager("stop");
    $.getJSON( apiCall)
        .done(function( json ) {
            console.log( "JSON Data: " + json );



            displayStill("/stills/"+makeThumb(json.filename));
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
            log("parseProgress: No progress.txt, indicating this is brand new");
            if(execOnStartup == false){
                log("parseProgress: Try again in one second");
                if(currentStatus == "isShooting"){
                    window.setTimeout("parseProgress(true, false)", 1000);
                }
            }
            if(currentStatus == "isLoading"){
                displayStatus("isReady");
            }
        }else{
            progressTxt = (data).split("\n");
            var progressIndex = parseInt(progressTxt[0]);
            var progressName = progressTxt[1];
            //put the current shoot name inside the input box
            $("#shootName").val(progressName);
            $("#shootName").prop( "disabled", true );
            var folderNum = Math.ceil((progressIndex+1)/1000)-1
            var latestImage = "/timelapse_"+progressName+"/group"+folderNum+"/image"+progressIndex+".jpg";
            if($("#manualSwitch2").is(":checked") == false){
                $("#manualSwitch2").click();
            }
            
            if (displayLatest){
                log("latestImage: "+latestImage);
                $("#messageViewport .isShootingTimelapse .imageOpen").attr("onclick", 'window.open("'+latestImage+'", "_blank")');
                
                displayStill(makeThumb(latestImage));

                if(progressIndex <10){ //first image is pesky, so we double load it just in case - this will actually display the first 10
                    window.setTimeout("parseProgress(true, false)", 2000);
                }
            }
            $("#status .isShootingTimelapse .extraInfo").html(" | Image "+  progressTxt[0]);
            
            if(execOnStartup){
                startTimelapseDelay();
            }
        }
    });
}


function timelapseMode(startOrStop){
    if (startOrStop == "start"){
        displayStatus("isShootingTimelapse");
        $("#photo-tab").addClass("disabled");
        $("#shootName").prop( "disabled", true );
        $("#timelapse-tab").click();
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
            
        }else{
            apiCall += "&pauseOrKill=pause";
        }


        $.getJSON( apiCall)
            .done(function( json ) {
                console.log(json );
                //alert("Timelapse in action. This is time consuming and heavy on the system. Doing too much, the system will crash.");
                //displayStill("latest.jpg");
                console.log("timelapse stoped");
                if($("#pauseOrKill").is(':checked')){
                    console.log("timelapse killed");
                    progressTxt = null;
                    $("#pauseOrKillWarning").addClass("d-none");
                    $("#shootName").prop( "disabled", false );
                    if($("#manualSwitch2").is(":checked")){
                        //nothing
                    }else{
                        $("#manualSwitch2").click();
                    }

                    
                }
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
    startTimelapseDelay()
    //window.setTimeout("", 1000); - unsure we really need this... 
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

    apiCall += "&raw=false&nightMode=normal";

    apiCall += "&shootName="+shootName;
    $.getJSON( apiCall)
    .done(function( json ) {
        console.log( json );
        log("timelapse: "+json.shootName + " - " + json.message);
        
        if(json.error){
            console.log("focus on input, show the manual controls")
            if($("#manualSwitch2").is(":checked") == false){
                $("#manualSwitch2").click();
            }
            $("#shootName").prop( "disabled", false );
            $("#shootName").focus();
            $("#newNameRequired").removeClass("d-none");
            $("#newNameRequired .shootName").html('"'+json.shootName+'"');
            
        }else{
            $("#newNameRequired").addClass("d-none");
           
            timelapseMode("start");
        }
        
    })
    .fail(function( jqxhr, textStatus, error ) {
        var err = textStatus + ", " + error;
        console.log( "Request Failed: " + err );
    });
}


function makeThumb(url){ 
    return url.split(".jpg")[0]+"_thumb.jpg";
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
        log("Update Code: "+ json.updateCodeResp);
        if(json.updateCodeResp.match(".py")){
            alert("LetsLapse requires a reset, please do so ASAP");
        }else{
            location.reload();
        }

    })
    .fail(function( jqxhr, textStatus, error ) {
        var err = textStatus + ", " + error;
        console.log( "Request Failed: " + err );
        log("Update Code ERROR: "+ error)
    });
}


function displayStatus(which){
    currentStatus = which;

    $("#messageViewport .statusMessage").addClass("d-none");
    $("#messageViewport ."+which).removeClass("d-none");


    $("#status .statusMessage").addClass("d-none");
    $("#status ."+which).removeClass("d-none");
}


function openGallery(){

    //$(".stillGalleryBtn").removeClass("active");
    if($(".timelapseGalleryBtn").hasClass("active")){
        getShoots();
    }else{
        getStills();
    }
}


function getShoots(filter){
    var apiCall = "/?action=getShoots";
    $.getJSON( apiCall)
    .done(function( json ) {
        console.log( "JSON Data: ");
        console.log(json);
        //displayStill("latest.jpg");
        //log("getShoots: "+ json.gallery);
        displayShoots(json.gallery);

    })
    .fail(function( jqxhr, textStatus, error ) {
        var err = textStatus + ", " + error;
        console.log( "Request Failed: " + err );
        log("getShoots ERROR: "+ error)
    });
}

var galleryApp = null;
function displayShoots(gallery){
    $("#stillsApp").addClass("d-none");
    $("#galleryApp").removeClass("d-none");
    var shoots = []
    for(var n=0; n<gallery.length; n++){
        var thisShoot = new Object();
        thisShoot.shootName = gallery[n][0];
        thisShoot.shootImages = gallery[n][1];
        shoots.push(thisShoot);
    }
    console.log(shoots);
    if(galleryApp == null){
        galleryApp = new Vue({
            el: '#galleryApp',
            data: {
                shoots:shoots
            }
        });
    }else{
        galleryApp.shoots = shoots;
    }
}

function getStills(){



    var apiCall = "/?action=getStills";
    $.getJSON( apiCall)
    .done(function( json ) {
        console.log( "JSON Data: ");
        console.log(json);
        //log("getStills: "+ json.stills);
        displayStills(json.stills);
    })
    .fail(function( jqxhr, textStatus, error ) {
        var err = textStatus + ", " + error;
        console.log( "Request Failed: " + err );
        log("getStills ERROR: "+ error)
    });


}
var stillsApp = null;
function displayStills(stills){
    $("#stillsApp").removeClass("d-none");
    $("#galleryApp").addClass("d-none");
    console.log(stills);
    if(stillsApp == null){
        stillsApp = new Vue({
            el: '#stillsApp',
            data: {
                stills:stills
            }
        });
    }else{
        stillsApp.stills = stills;
    }
}
