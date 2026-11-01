# Import blocks for objects that already exist on the controller. Temporary:
# delete after the first approved apply. The BGP config is a per-site
# singleton, its import ID is the site name.

import {
  to = unifi_bgp.this
  id = "default"
}
