function searchLocationAjax(event, obj){
    //Letters, Caps and nums
    if ( (event.which > 64 && event.which < 91) || (event.which > 96 && event.which < 123) || (event.which > 47 && event.which < 58)) {
        if ( obj.value.length > 2 ){
            var items = "";
            var get = 0;
            $('ul.l-calles').empty();
            if (obj.id == 'esquina'){
                if (!isNaN(obj.value)){
                    items += "<li id='" + obj.value + "' class='pick-street' onclick='streetLocate(this)' >" + obj.value + "</li>";
                    $('ul.l-calles').empty();
                    $(items).appendTo("ul.l-calles");
                }
                else {
                    if ( ( listaCalles[1] != undefined ) && ( listaCalles[1].length > 1 ) && ( listaCalles[1][0] == obj.value.substring(0, listaCalles[1][0].length) ) ){
                        //quitamos el primer termino y vemos el length
                        listaCalles[1].shift();
                        $.each( listaCalles[1], function( addr_key, addr_obj ) {
                            if ( addr_obj.address.indexOf( obj.value.toUpperCase() ) >= 0){
                                items += "<li id='" + addr_obj.lat + "' class='pick-street' onclick='streetLocate(this)' >" + addr_obj.address + "</li>";
                            }
                            else{
                                listaCalles[0].splice(addr_key, 1);
                            }
                        });
                        //agregamoe el término al comienzo
                        listaCalles[1].splice(0, 0, obj.value);
                        $('ul.l-calles').empty();
                        $(items).appendTo("ul.l-calles");
                    }
                    else {
                        var code = $('input#main-street-code');
                        if ( !code.val() ){
                            items = "<li class='pick-street-error'>Debe ingresar una calle primero</li>";
                            $('ul.l-calles').empty();
                            $(items).appendTo("ul.l-calles");
                        }
                        else{
                            $('#esquina').css("background", "url(/cobrands/pormibarrio/images/Loading.gif) 25px 18px no-repeat");
                            $.getJSON( "/ajax/geocode?term="+area+","+code.val()+','+obj.value, function( data ) {
                                //vaciamos el array
                                listaCalles[1] = [];
                                listaCalles[1][0] = obj.value;
                                $.each( data.locations, function( key, obj ) {
                                    items += "<li id='" + obj.lat + "' class='pick-street' onclick='streetLocate(this)' >" + obj.address + "</li>";
                                    listaCalles[1].push(obj);
                                });
                                $('ul.l-calles').empty();
                                $(items).appendTo("ul.l-calles");
                                $('#esquina').css("background", "url(/cobrands/pormibarrio/images/icon-search.png) 25px 18px no-repeat");
                            });
                        }
                    }
                }
            }
            else {
                if ( ( listaCalles[0] != undefined ) && ( listaCalles[0].length > 1 ) && (listaCalles[0][0] == obj.value.substring(0, listaCalles[0][0].length) ) ){
                    //quitamos el primer termino
                    newList = [listaCalles[0].shift()];
                    $.each( listaCalles[0], function( addr_key, addr_obj ) {
                        if (  addr_obj != undefined && addr_obj.address.indexOf( obj.value.toUpperCase() ) >= 0){
                            items += "<li id='" + addr_obj.lat + "' class='pick-street' onclick='assignStreetValue(this)' >" + addr_obj.address + "</li>";
                            newList.push(addr_obj);
                        }
                    });
                    //agregamos la nueva lista
                    listaCalles[0] = newList;
                    $('ul.l-calles').empty();
                    $(items).appendTo("ul.l-calles");
                }
                else {
                    $('#calle').css("background", "url(/cobrands/pormibarrio/images/Loading.gif) 25px 18px no-repeat");
                    $.getJSON( "/ajax/geocode?term="+area+","+obj.value, function( data ) {
                        listaCalles[0] = [];
                        listaCalles[0][0] = obj.value;
                        $.each( data.locations, function( key, obj ) {
                            items += "<li id='" + obj.lat + "' class='pick-street' onclick='assignStreetValue(this)' >" + obj.address + "</li>";
                            listaCalles[0].push(obj);
                        });
                        $('ul.l-calles').empty();
                        $(items).appendTo("ul.l-calles");
                        $('#calle').css("background", "url(/cobrands/pormibarrio/images/icon-search.png) 25px 18px no-repeat");
                    });
                }
            }
        }
    }
}

function assignStreetValue(obj){
    $('input#calle').val($(obj).text());
    $('input#main-street-code').val(obj.id);
    $('ul.l-calles').empty();
}

function streetLocate(obj){
    $('input#esquina').val($(obj).text());
    $('input#second-street-code').val(obj.id);
    $('ul.l-calles').empty();
    if ( isNaN(obj.innerHTML) ){
        var url = "/ajax/geocode?term="+area+","+$('input#main-street-code').val() +','+obj.id+',corner';
    }
    else {
        var url = "/ajax/geocode?term="+area+","+ $('input#main-street-code').val() +','+obj.id+',door';
    }
    streetLocateSubmit(url);
}
function streetLocateSubmit(url){
    if ( $('input#main-street-code').val() && $('input#second-street-code').val() ){
        if (url == 'none')
            url = "/ajax/geocode?term="+area+","+ $('input#main-street-code').val() +','+$('input#second-street-code').val()+', final';
            $.ajax({
              url: url,
              dataType: 'json',
              success: function( data ) {
                locateStreetPin(data);
              },
              error: function( data ) {
                var fixedResult = data.responseText.replace(/,/g, ".");
                fixedResult = fixedResult.replace('."l', ',"l');
                fixedResult = fixedResult.replace('"{', '{');
                fixedResult = fixedResult.replace('}"', '}');
                var fixed_data = JSON.parse(fixedResult);
                locateStreetPin(fixed_data);
              }
            });
    }
    else {
        $('ul.l-calles').empty();
        if ( !$('input#main-street-code').val() ){
            $('input#calle').addClass('street-error');
            items = "<li class='pick-street-error'>Debe ingresar una calle primero</li>";
            $(items).appendTo("ul.l-calles");
        }
        if ( !$('input#second-street-code').val() ){
            $('input#esquina').addClass('street-error');
            items = "<li class='pick-street-error'>Debe ingresar una una esquina o número</li>";
            $(items).appendTo("ul.l-calles");
        }
    }
}

function locateStreetPin(data){
  var latlon = utm2LatLong(data.latitude, data.longitude, '21H');
  if (typeof fixmystreet != "undefined"){
    var lonlat = new OpenLayers.LonLat(latlon[1], latlon[0]);
    lonlat.transform(new OpenLayers.Projection("EPSG:4326"),new OpenLayers.Projection("EPSG:900913"));
    fixmystreet.map.panTo(lonlat);
    fixmystreet_update_pin(lonlat,0);
    if (fixmystreet.page == 'new') {
        /* Already have a pin */
        fixmystreet.markers.features[0].move(lonlat);
    } else {
        var markers = fms_markers_list( [ [ lonlat.lat, lonlat.lon, 'green' ] ], false );
        fixmystreet.bbox_strategy.deactivate();
        fixmystreet.markers.removeAllFeatures();
        fixmystreet.markers.addFeatures( markers );
        fixmystreet_activate_drag();
    }
    setTimeout(function(){
      fixmystreet.map.zoomTo(3);
    },500);
  }else{
    window.location.href = "/around?latitude="+latlon[0]+";longitude="+latlon[1]+"&zoom=3";
  }
}
