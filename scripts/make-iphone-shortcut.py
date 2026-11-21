#!/usr/bin/env python3
"""Generate an unsigned, unconfigured Toss shortcut for signing.

Shortcuts fills the first text action locally at import time. Both the Mac
and phone imports store the answer in the shortcut itself, so Back Tap can
run from another app without opening a file provider.
"""

import argparse
from pathlib import Path
import plistlib
from uuid import uuid4


# Accept a single trailing line ending from the import form. Only the matched
# address and key are used in the handshake.
PAIRING_PATTERN = r"\Ahttp://[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.local:54963\|[0-9a-f]{64}(?=(?:\r?\n)?\z)"
NONCE_PATTERN = r"\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z"


def make_shortcut(setup, phone_setup=False):
    if setup != "":
        raise ValueError("Shared Toss templates must have an empty setup")
    actions = []
    title = "Toss Tap" if phone_setup else "Toss iPhone"

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

    def match(value, pattern):
        return add("text.match", "Matches", text=text(value), WFMatchTextPattern=pattern,
                   WFMatchTextCaseSensitive=True)

    def stop_if(output, condition, message=None, value=None):
        group = str(uuid4()).upper()
        parameters = {"GroupingIdentifier": group, "WFControlFlowMode": 0, "WFCondition": condition,
                      "WFInput": {"Type": "Variable", "Variable": variable(output)}}
        if value is not None:
            parameters["WFConditionalActionString"] = value
        add("conditional", "If", **parameters)
        if message:
            add("alert", "Toss", WFAlertActionTitle=title, WFAlertActionMessage=message,
                WFAlertActionCancelButtonShown=False)
        add("nothing", "Nothing")
        add("exit", "Stop")
        add("conditional", "If Result", GroupingIdentifier=group, WFControlFlowMode=2)

    setup_text = add("gettext", "Toss Setup", WFTextActionText=setup)
    command = add("gettext", "Command", WFTextActionText=text("Toss", {"Type": "ExtensionInput"}))
    stop_if(match(command, r"\AToss(?:/authorize)?\z"), 101)
    # A missing match contributes an empty suffix. Only this fixed literal can
    # reach the URL, including when the caller passes unexpected shortcut input.
    suffix = match(command, r"(?<=\AToss)/authorize\z")

    configuration = match(setup_text, PAIRING_PATTERN)
    stop_if(configuration, 101,
            "请从 Mac 的 Toss 复制配对配置，重新添加此捷径，并在添加时粘贴。\n"
            "Copy the pairing setup from Toss on your Mac and paste it when adding this shortcut again.")
    parts = add("text.split", "Configuration", text=text(configuration),
                WFTextSeparator="Custom", WFTextCustomSeparator="|")
    address = add("getitemfromlist", "Mac Address", WFInput=variable(parts), WFItemSpecifier="First Item")
    secret = add("getitemfromlist", "Pairing Secret", WFInput=variable(parts), WFItemSpecifier="Last Item")

    # Both modes share the same URL actions and their first-run permissions.
    reply = add("downloadurl", "Challenge", WFURL=text(address, "/toss/iphone/challenge", suffix))
    nonce = match(reply, NONCE_PATTERN)
    stop_if(nonce, 101, "请确认 Mac 上的 Toss 已打开，再试一次。\nOpen Toss on your Mac and try again.")
    proof_input = add("gettext", "Proof Input", WFTextActionText=text("Toss iPhone ", nonce, " ", secret))
    proof = add("hash", "Proof", WFInput=variable(proof_input), WFHashType="SHA256")
    response = add("downloadurl", "Toss Response", WFHTTPMethod="POST", WFHTTPBodyType="JSON",
                   WFURL=text(address, "/toss/iphone/capture/", nonce, "/", proof))
    # A successful capture or authorization has an empty response body.
    result = add("gettext", "Result", WFTextActionText=text("Toss:", response))
    stop_if(result, 5, text("Mac 未完成请求 / Mac couldn't complete the request.\n", response), value="Toss:")
    add("nothing", "Nothing")

    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2600",
        "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": 59788, "WFWorkflowIconStartColor": 2071128575},
        "WFWorkflowImportQuestions": [{
            "ActionIndex": 0,
            "Category": "Parameter",
            "ParameterKey": "WFTextActionText",
            "Text": "粘贴 Toss 复制的配置 / Paste setup from Toss",
            "DefaultValue": "",
        }],
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowTypes": [],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phone-setup", action="store_true", help="build the direct iPhone import")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_bytes(plistlib.dumps(make_shortcut("", args.phone_setup), fmt=plistlib.FMT_BINARY, sort_keys=False))
