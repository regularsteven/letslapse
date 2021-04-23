console.log("main controler");

function setImageViewer(index){
    document.getElementById("viewer").style.backgroundImage = "url('"+projectPath+"seq-"+index+".jpg')";
}

function rangeSlide(value) {
    
    //            document.getElementsByClassName("range")[0].value
                document.getElementById('rangeValue').innerHTML = value;

                setImageViewer(value);
            }


var projectPath = "/projects/sample/jpg-tiny/";

function start(){

    setImageViewer(1);
}


start();