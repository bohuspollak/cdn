# Janoszens Static CDN

This software is designed to implement a bespoke CDN for owners of static websites built with Jekyll and the likes. It
offers.

## Requirements

- An Amazon Web Services account.
- A domain which has DNS hosted on Amazon Route53.
- A subdomain that the CDN can use internally.
- Willingness to run 5-6 CDN nodes using Amazon Lightsail or EC2.

## Edge nodes

The edge nodes are running OpenResty (nginx + lua modules) to deliver content, as well as a queue processor that watches
a queue for content updates. If an update is detected, the content is downloaded in tar format, extracted and then moved
for usage on the webserver. For details on the tar layout, see the section [Archive layout](#archive-layout) below.
Deployments are atomic on one edge node only.

## Master node

The master node is responsible for running the API that accepts tar archives for deployment (with authentication), if
needed generates SSL certificates for them, and then notifies the edge nodes via a queue that an update is pending.

The master CAN be run in conjunction with a CDN node, but it must be configured to run on a different IP or port.

## Archive layout

The archive layout used for the content transfer is the following:

- `ssl/`
  - `privatekey.pem`: contains the private key. If missing, the master node will generate a private key.
  - `fullchain.pem`: contains the full X509 certificate chain. If missing, the master node will request a certificate from LetsEncrypt.
- `config/`: contains routing configuration
  - `redirects`: Tab delimited file that contains the match regexp (nginx) in column 1, the target redirect in column 2 ($1-9 can be used for replacements), and the HTTP status code in column 3.
  - `slashes`: Text file that can contain either "yes" or "no" to add or remove slashes from URLs.
  - `caching`: Tab-delimited file. Column 1 should contain a regexp for a path, column 2 should contain a mime type (regexp), column 3 should contain an expiry time.
  - `headers`: Contains a tab-delimited file. Column 1 should contain a regexp for a path, column 2 should contain a mime type (regex), column 3 should contain a header name and column 4 should contain the header contents.  
- `htdocs/`: contains the web root.
  - `index.html`: Default page for directory.
  - `.index.html`: Alternative name for the index.html
  - `.400.html`: HTTP 400 error page
  - `.401.html`: HTTP 401 error page
  - `.403.html`: HTTP 403 error page
  - `.404.html`: HTTP 404 error page
  - `.405.html`: HTTP 405 error page
  - `.406.html`: HTTP 406 error page
  - `.408.html`: HTTP 408 error page
  - `.413.html`: HTTP 413 error page
  - `.414.html`: HTTP 414 error page
  - `.417.html`: HTTP 417 error page
  - `.500.html`: HTTP 500 error page

These files must be packed up into a tar archive (not .tar.gz) and sent to the master node.
