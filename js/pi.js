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

var presets = [];
presets["sunnyDay"] = {ss: 100, iso: 10};
presets["sunnyForrest"] = {ss: 5000, iso: 10};
presets["sunset"] = {ss: 20000, iso: 75};
presets["night"] = {ss: 6 * 100000, iso: 1600};
presets["nightUrban"] = {ss: 2 * 100000, iso: 800};
presets["nightNature"] = {ss: 6 * 100000, iso: 800};

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


function streamManager(startOrStop){
    if(startOrStop == "start"){
        document.getElementById("imageViewport").style.backgroundImage = "none";
        stream = ""
        if(window.location.host == "127.0.0.1"){
            console.log("local testing, see if the device is on the network")
            stream += "http://10.3.141.212:8081"
        }else{
            stream += "http://"+window.location.host+":8081";
        }
        stream += "/stream.mjpg"
        document.getElementById("imageViewport").style.backgroundImage = "url('"+stream+"')";
    }else{
        window.stop();
        
    }

}



window.addEventListener("load", function(){
    console.log("document loaded");
    streamManager("start");
});
/* V.1 Release */ 

function takeStill(){
    $.getJSON( apiCall)
        .done(function( json ) {
            console.log( "JSON Data: " + json );
            streamManager("start");
        })
        .fail(function( jqxhr, textStatus, error ) {
            var err = textStatus + ", " + error;
            console.log( "Request Failed: " + err );
  });
}
