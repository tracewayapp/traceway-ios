import Foundation

/// One node of the wireframe DOM: an element or a text node.
///
/// Nodes are immutable. A capture reuses the previous frame's node when
/// nothing about it changed, so consecutive frames share their unchanged
/// subtrees: a frame costs memory only for what moved, and a diff skips
/// every subtree that is the same object in both frames.
final class VNode {
    /// The rrweb node id. The same view keeps its id from frame to frame.
    let id: Int
    /// Nil for a text node.
    let tag: String?
    let text: String?
    let attributes: [String: String]
    let children: [VNode]

    init(element id: Int, tag: String, attributes: [String: String], children: [VNode]) {
        self.id = id
        self.tag = tag
        self.text = nil
        self.attributes = attributes
        self.children = children
    }

    init(text id: Int, text: String) {
        self.id = id
        self.tag = nil
        self.text = text
        self.attributes = [:]
        self.children = []
    }

    var isText: Bool { tag == nil }

    /// Whether this node shows the same as `other`: same tag, text and
    /// attributes, and children that are the very same objects.
    func sameAs(_ other: VNode) -> Bool {
        guard id == other.id, tag == other.tag, text == other.text,
              attributes == other.attributes, children.count == other.children.count
        else { return false }
        for i in 0..<children.count where children[i] !== other.children[i] {
            return false
        }
        return true
    }

    /// The node in rrweb's serialized form. A full snapshot nests the whole
    /// subtree; a mutation adds every node on its own, so it leaves the
    /// children out.
    func serialize(withChildren: Bool = true) -> JSON {
        if isText {
            return ["type": 3, "textContent": .string(text ?? ""), "id": JSON(id)]
        }
        return [
            "type": 2,
            "tagName": .string(tag ?? "div"),
            "attributes": JSON(attributes),
            "childNodes": withChildren ? .array(children.map { $0.serialize() }) : .array([]),
            "id": JSON(id),
        ]
    }
}

/// Ids of the document skeleton around the captured screen.
let documentNodeId = 1
private let doctypeNodeId = 2
private let htmlNodeId = 3
private let headNodeId = 4
private let charsetNodeId = 5
private let styleNodeId = 6
private let bodyNodeId = 7

/// The element that holds the screen; every captured node is inside it.
let screenNodeId = 8

/// Fixed ids of nodes the recorder draws itself (below the first captured
/// id): the screen shown while the app is in the background, and the
/// keyboard placeholder.
let awayScreenTextBoxId = 9
let awayScreenTextId = 10
let keyboardNodeId = 12
let keyboardLabelBoxId = 13
let keyboardLabelTextId = 14

/// The first id handed to a captured node.
let firstCapturedNodeId = 16

/// Shared rules of every wireframe, the same classes as the Flutter SDK's.
/// Each node carries its geometry and colors inline; these set the defaults
/// and the placeholder looks.
let wireframeCss = """
html,body{margin:0;padding:0;overflow:hidden;background:#000}
body{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased;-webkit-text-size-adjust:none;text-size-adjust:none}
#tw{position:relative;overflow:hidden}
#tw div,#tw img{position:absolute;left:0;top:0;box-sizing:border-box;margin:0}
.t{white-space:pre-wrap;overflow-wrap:break-word;line-height:1.17}
.n{white-space:pre;display:flex}
.e{display:block;overflow:hidden;text-overflow:ellipsis}
.k{display:block;overflow:hidden}
.im{background-color:rgba(158,158,158,.22);background-image:linear-gradient(to top right,transparent calc(50% - .5px),rgba(128,128,128,.45) 50%,transparent calc(50% + .5px)),linear-gradient(to bottom right,transparent calc(50% - .5px),rgba(128,128,128,.45) 50%,transparent calc(50% + .5px))}
.ic::before{content:"";position:absolute;inset:14%;border-radius:30%;background:currentColor;opacity:.62}
.cp{border:1px dashed rgba(128,128,128,.5)}
.mk{background-image:repeating-linear-gradient(45deg,rgba(255,255,255,.08) 0 6px,transparent 6px 12px)}
.sk{color:#8e8e93}
.sk::before{content:"";position:absolute;left:0;right:0;top:22%;bottom:22%;border-radius:4px;background:currentColor;opacity:.35}
.sk.sm::before{top:6%;bottom:6%;border-radius:0;background:repeating-linear-gradient(to bottom,currentColor 0 13px,transparent 13px 20px)}
.pv{display:flex;align-items:center;justify-content:center;overflow:hidden;background-color:#eceff1;background-image:repeating-linear-gradient(135deg,rgba(96,125,139,.16) 0 10px,transparent 10px 20px);box-shadow:inset 0 0 0 1px rgba(96,125,139,.45);color:#455a64;font-size:13px;font-weight:500;text-align:center}

"""

/// The rrweb document of a full snapshot, with `screen` inside its body.
func serializeDocument(_ screen: VNode) -> JSON {
    [
        "type": 0,
        "id": JSON(documentNodeId),
        "childNodes": [
            [
                "type": 1,
                "name": "html",
                "publicId": "",
                "systemId": "",
                "id": JSON(doctypeNodeId),
            ],
            [
                "type": 2,
                "tagName": "html",
                "attributes": [:],
                "id": JSON(htmlNodeId),
                "childNodes": [
                    [
                        "type": 2,
                        "tagName": "head",
                        "attributes": [:],
                        "id": JSON(headNodeId),
                        "childNodes": [
                            [
                                "type": 2,
                                "tagName": "meta",
                                "attributes": ["charset": "utf-8"],
                                "childNodes": [],
                                "id": JSON(charsetNodeId),
                            ],
                            [
                                "type": 2,
                                "tagName": "style",
                                "attributes": ["_cssText": .string(wireframeCss)],
                                "childNodes": [],
                                "id": JSON(styleNodeId),
                            ],
                        ],
                    ],
                    [
                        "type": 2,
                        "tagName": "body",
                        "attributes": [:],
                        "id": JSON(bodyNodeId),
                        "childNodes": [screen.serialize()],
                    ],
                ],
            ],
        ],
    ]
}
