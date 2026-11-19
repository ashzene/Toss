#!/usr/bin/env python3
"""Build the importable iPhone shortcut with placeholders only.

To refresh the signed template, run this script with an output path, then use
shortcuts sign --mode anyone --input <output> --output "Assets/Toss iPhone.shortcut".
The user's local address and secret are entered on import, after signing.
"""

import argparse
from pathlib import Path
import plistlib
from uuid import uuid4


def make_shortcut(setup):
    actions = []

    def add(action, output, **parameters):
        action_id = str(uuid4()).upper()
        parameters["UUID"] = action_id
        actions.append({
            "WFWorkflowActionIdentifier": "is.workflow.actions." + action,
            "WFWorkflowActionParameters": parameters,
        })
        return {"Type": "ActionOutput", "OutputName": output, "OutputUUID": action_id}

    def variable(output):
        return {"WFSerializationType": "WFTextTokenAttachment", "Value": output}

    def text(*segments):
        string, attachments = "", {}
        for segment in segments:
            if isinstance(segment, str):
                string += segment
            else:
                offset = len(string.encode("utf-16-le")) // 2
                attachments[f"{{{offset}, 1}}"] = segment
                string += "\ufffc"
        return {
            "WFSerializationType": "WFTextTokenString",
            "Value": {"string": string, "attachmentsByRange": attachments},
        }

    configuration = add("gettext", "Toss Setup", WFTextActionText=setup)
    parts = add("text.split", "Configuration", text=variable(configuration),
                WFTextSeparator="Custom", WFTextCustomSeparator="|")
    address = add("getitemfromlist", "Mac Address", WFInput=variable(parts), WFItemSpecifier="First Item")
    secret = add("getitemfromlist", "Pairing Secret", WFInput=variable(parts), WFItemSpecifier="Last Item")
    # Back Tap has no input. The Mac can supply /authorize to check the same host
    # and pairing without starting a capture.
    challenge = add("downloadurl", "Challenge", WFURL=text(address, "/toss/iphone/challenge", {"Type": "ExtensionInput"}))
    proof_input = add("gettext", "Proof Input", WFTextActionText=text("Toss iPhone ", challenge, " ", secret))
    proof = add("hash", "Proof", WFInput=variable(proof_input), WFHashType="SHA256")
    add("downloadurl", "Toss Response", WFHTTPMethod="POST", WFHTTPBodyType="JSON",
        WFURL=text(address, "/toss/iphone/capture/", challenge, "/", proof))

    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2600",
        "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": 59788, "WFWorkflowIconStartColor": 2071128575},
        "WFWorkflowImportQuestions": [{
            "ActionIndex": 0,
            "Category": "Parameter",
            "ParameterKey": "WFTextActionText",
            "Text": "粘贴 Toss 复制的配置 / Paste setup from Toss",
            "DefaultValue": setup,
        }],
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowTypes": [],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_bytes(plistlib.dumps(make_shortcut(""), fmt=plistlib.FMT_BINARY, sort_keys=False))
