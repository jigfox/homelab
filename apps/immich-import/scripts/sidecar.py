"""XMP sidecars for the Immich import.

Which XMP field carries the tags (Immich v3.3.5, server/src/services/metadata.service.ts,
getTagList): the first field that exists wins, in this order:
  1. TagsList            (XMP-digiKam:TagsList, "a/b/c" paths)
  2. HierarchicalSubject (XMP-lr, "a|b|c")
  3. Keywords            (XMP-dc:Subject / IPTC, flat)
Tags are split on "/" and every level becomes a tag ("Quelle/Arq/Photos/2014"
creates Quelle, Quelle/Arq, ...). Sidecar tags are merged over the file's own
({...mediaTags, ...sidecarTags}), so a TagsList in the sidecar replaces any tag
list of the file for this purpose. We therefore write the catalog keywords AND
the source tag into digiKam:TagsList (the field Immich prefers), and keep the
keywords in dc:subject as well for other tools.

Everything else in a sidecar also overrides the file's own metadata, so the
catalog XMP is stripped of orientation and pixel dimensions (the file is the
authority there). Leftovers get a sidecar with the tag list only.
"""
import re
from xml.sax.saxutils import escape

NS_DK = 'xmlns:digiKam="http://www.digikam.org/ns/1.0/"'
NS_DC = 'xmlns:dc="http://purl.org/dc/elements/1.1/"'
NS_XMP = 'xmlns:xmp="http://ns.adobe.com/xap/1.0/"'
SOURCE_PREFIX = "Quelle/Arq/"

_STRIP = re.compile(
    r'\s+(?:tiff:Orientation|tiff:ImageWidth|tiff:ImageLength|exif:PixelXDimension|exif:PixelYDimension)="[^"]*"')
_DESC = re.compile(r'<rdf:Description\b')


def source_tag(directory):
    """directory: backup directory of the file, e.g. 'Photos/2014/2014-11 Malediven'."""
    return SOURCE_PREFIX + directory


def clean_keyword(name):
    # "/" would become a hierarchy level in Immich
    return name.replace("/", "-").strip()


def _seq(tag, kind, values):
    items = "".join(f"<rdf:li>{escape(v)}</rdf:li>" for v in values)
    return f"<{tag}><rdf:{kind}>{items}</rdf:{kind}></{tag}>"


def minimal(tag):
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
        f'<rdf:Description rdf:about="" {NS_DK}>'
        + _seq("digiKam:TagsList", "Seq", [tag]) +
        '</rdf:Description></rdf:RDF></x:xmpmeta>\n'
    ).encode()


def from_catalog(xmp, keywords, caption, rating, tag):
    """xmp: Lightroom's per-image XMP (text); returns sidecar bytes."""
    m = _DESC.search(xmp)
    if not m or "</rdf:Description>" not in xmp:
        return minimal(tag)  # unexpected structure: do not risk a broken sidecar
    xmp = _STRIP.sub("", xmp)
    m = _DESC.search(xmp)
    head = xmp[:m.end()]
    ns = ""
    for decl in (NS_DK, NS_DC, NS_XMP):
        if decl.split("=")[0] not in xmp:
            ns += " " + decl
    attrs = ""
    if rating and 1 <= rating <= 5 and "xmp:Rating" not in xmp:
        attrs = f' xmp:Rating="{rating}"'
    body = ""
    if keywords and "<dc:subject" not in xmp:
        body += _seq("dc:subject", "Bag", keywords)
    if caption and "<dc:description" not in xmp:
        body += (f'<dc:description><rdf:Alt><rdf:li xml:lang="x-default">{escape(caption)}'
                 '</rdf:li></rdf:Alt></dc:description>')
    body += _seq("digiKam:TagsList", "Seq", list(keywords) + [tag])
    out = head + ns + attrs + xmp[m.end():]
    i = out.rindex("</rdf:Description>")
    return (out[:i] + body + out[i:]).encode()
