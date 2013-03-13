Some people have asked how I implemented WebLogger on my site regoroad.com.  I apologize to how
rough this implementation is, and one day I will make it cleaner, and easier to setup, but for
now...here's some rough instructions on how to do the same on your site.

This particular implementation was done on a wordpress blog, but the basics are all here to be
able to do this in just about any environment, provided you have PHP, and a way to upload the
"now playing" information to your site.



The way this implementation works...

1. Weblogger is configured in Squeezecenter to upload "now playing" information to a web
   server (FTP in my case)
2. A small PHP widget is created that basically takes those "now playing" files, and embeds
   them in a web page (with appropriate IDs)
3. A javascript file is loaded that automatically cycles through those "now playing"
   blocks, and displays them in order using fancy transitions.



For wordpress...

1. Install "PHP Code" widget in wordpress
2. Create a widget using the code found in weblogger-wp-widget.php
3. Place weblogger.js in a web-accessible location (making sure that location is matched
   in the first line of the "weblogger-wp-widget.php" file)
4. Configure weblogger to upload your templates to a dir on your webserver, and to upload it
   as index.html
5. Modify/configure "weblogger-wp-widget.php"
    - "file_get_contents" contains the path/location where the index.html files should be
      found.
    - The $dirs array should be set to whatever the sub-dirs for each of your uploaded
      templates are.
6. Modify the "show_weblogger_page()" function in the javascript file to use whatever
   transition you desire.  (just replace show_weblogger_page_fade with any of the other
   included in this file, or create your own)

