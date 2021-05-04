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