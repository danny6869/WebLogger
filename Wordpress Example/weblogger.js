/* Javascript functions for the weblogger now playing widget
   ...displaying multiple with fancy transitions */

var current_index=0;
var maximum_weblogger_pages=0;
var weblogger_page_prefix="weblogger-playing-";
var weblogger_box_id=weblogger_page_prefix + 'box';
var weblogger_spring_movement=0;

function init_weblogger_pages(page_count) {
    maximum_weblogger_pages=page_count;

    var box_item=$(weblogger_box_id);
    weblogger_spring_movement=box_item.getWidth();

    for(var i=1;i<=maximum_weblogger_pages;i++) {
        var item=$(weblogger_page_prefix + i);

        if(item.getHeight()>=box_item.getHeight()) {
            box_item.clonePosition(item,{setLeft: false, setTop: false, setWidth: false});
        }

        item.absolutize();
        item.clonePosition(box_item,{setHeight: false});
//        new Effect.Move(item, {
//            duration: 0.0,
//            x: weblogger_spring_movement,
//        });
        item.setOpacity(0.0);
    }

    show_weblogger_page(1);
}

function show_weblogger_page(num) {
    var ret=show_weblogger_page_fade(num);
// XXX - Re-fetch the content, and fill the box...
    return ret;
}

function show_weblogger_page_puff(num) {
    var box_item=$(weblogger_box_id);
    var old_item=$(weblogger_page_prefix + current_index);
    var new_item=$(weblogger_page_prefix + num);

    if(current_index!=0) {
        new Effect.Puff(old_item, {
            duration: 1.0,
            afterFinish: function() {
                old_item.setOpacity(0.0);
                old_item.show();
                old_item.clonePosition(box_item);
            }
        });
    }

    new Effect.Opacity(new_item, {
        duration: 1.5,
        from: 0.0,
        to: 1.0,
        beforeStart: function() {
            new_item.clonePosition(box_item);
        }
    });

    current_index=num;
    set_next_weblogger_page_timer();
    return false;
}

function show_weblogger_page_fade(num) {
    var box_item=$(weblogger_box_id);
    var old_item=$(weblogger_page_prefix + current_index);
    var new_item=$(weblogger_page_prefix + num);

    if(current_index!=0) {
        new Effect.Opacity(old_item, {
            duration: 1.0,
            from: 1.0,
            to: 0.0,
        });
    }

    new Effect.Opacity(new_item, {
        duration: 1.5,
        from: 0.0,
        to: 1.0,
        beforeStart: function() {
            new_item.clonePosition(box_item);
        }
    });

    current_index=num;
    set_next_weblogger_page_timer();
    return false;
}


function show_weblogger_page_slide(num) {
    var box_item=$(weblogger_box_id);
    var old_item=$(weblogger_page_prefix + current_index);
    var new_item=$(weblogger_page_prefix + num);

    if(current_index==0) {
        // Our first showing...
//        new_item.relativize();
        new_item.setOpacity(1.0);
        new Effect.Move(new_item, {
            duration: 1.0,
            x: -weblogger_spring_movement,
            transition: Effect.Transitions.spring
        });
    } else {
        // Switching from one to another...
        new Effect.Move(old_item, {
            duration: 0.5,
            x: +weblogger_spring_movement,
            transition: Effect.Transitions.spring,
            afterFinish: function() {
                old_item.setOpacity(0.0);
//                old_item.absolutize();
//                new_item.relativize();
                new_item.setOpacity(1.0);
                new Effect.Move(new_item, {
                    duration: 1.0,
                    x: -weblogger_spring_movement,
                    transition: Effect.Transitions.spring
                });
            }
        });
    }

    current_index=num;
    set_next_weblogger_page_timer();
    return false;
}

function show_next_weblogger_page() {
    var new_page=current_index+1;
    if(new_page>maximum_weblogger_pages) {
        new_page=new_page-maximum_weblogger_pages;
    }
    show_weblogger_page(new_page);
}

function set_next_weblogger_page_timer() {
    if(maximum_weblogger_pages>1) {
        setTimeout("show_next_weblogger_page()",3000);
    }
}

function fetch_weblogger_page(url,container_id) {

    new Ajax.Request(url, {
        method:'get',
        onSuccess: function(transport){
            var response = transport.responseText || "no response text";
            alert("Success! \n\n" + response);
        },
        onFailure: function(){ alert('Something went wrong...') }
    });

}

