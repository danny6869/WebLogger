<script type="text/javascript" src="/custom_html/js/weblogger.js"></script>

<?php
    $dirs=array("Basement","Backyard","Master Bedroom","Kitchen","Desktop Computer","Work Computer");

    $count=1;
    print "<div id=\"weblogger-playing-box\" style=\"overflow: hidden;\">\n";
    foreach ($dirs as $dir_name) {

        $include_text = file_get_contents  ( "files/WebLogger/Output/$dir_name/index.html" );

        $include_text_replaced = preg_replace  ( "/\/WebLogger/"  ,  "http://files.regoroad.com/WebLogger"  ,  $include_text );

        print "<div id=\"weblogger-playing-$count\" style=\"position: absolute; white-space: nowrap;\">\n";
        print "$include_text_replaced";
        print "</div>";

        $count++;

    }
    print "</div>";

?>

<script type="text/javascript">
        init_weblogger_pages(<?php print count($dirs) ?>);
</script>
