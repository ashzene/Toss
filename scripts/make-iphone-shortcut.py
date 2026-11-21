#!/usr/bin/env python3
"""Generate an unsigned, unconfigured Toss shortcut for signing.

Mac imports use an inline text action. The direct iPhone workflow pairs
from a QR link and saves its validated configuration locally.
"""

import argparse
from pathlib import Path
import plistlib
from uuid import uuid4


# Accept a single trailing line ending from the import form. Only the matched
# address and key are used in the handshake.
CONFIGURATION = r"http://[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.local:54963\|[0-9a-f]{64}"
PAIRING_PATTERN = rf"\A{CONFIGURATION}(?=(?:\r?\n)?\z)"
NONCE_PATTERN = r"\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z"
# Settings can open this page on iPhone, but the user still chooses the shortcut.
BACK_TAP_SETTINGS = "prefs:root=ACCESSIBILITY&path=TOUCH_REACHABILITY_TITLE/BackTap/DoubleTap"


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

    def request(configuration, suffix):
        parts = add("text.split", "Configuration", text=text(configuration),
                    WFTextSeparator="Custom", WFTextCustomSeparator="|")
        address = add("getitemfromlist", "Mac Address", WFInput=variable(parts), WFItemSpecifier="First Item")
        secret = add("getitemfromlist", "Pairing Secret", WFInput=variable(parts), WFItemSpecifier="Last Item")
        challenge = add("downloadurl", "Challenge", WFURL=text(address, "/toss/iphone/challenge", suffix))
        nonce = match(challenge, NONCE_PATTERN)
        stop_if(nonce, 101, "请打开 Mac 上的 Toss，再试一次。\nOpen Toss on your Mac and try again.")
        material = add("gettext", "Proof Input", WFTextActionText=text("Toss iPhone ", nonce, " ", secret))
        proof = add("hash", "Proof", WFInput=variable(material), WFHashType="SHA256")
        return add("downloadurl", "Toss Response", WFHTTPMethod="POST", WFHTTPBodyType="JSON",
                   WFURL=text(address, "/toss/iphone/capture/", nonce, "/", proof))

    if not phone_setup:
        setup_text = add("gettext", "Toss Setup", WFTextActionText=setup)
    command = add("gettext", "Command", WFTextActionText=text("Toss", {"Type": "ExtensionInput"}))
    if phone_setup:
        # A QR enrollment must reach the Mac before any local file lookup.
        folder = {"filename": "", "displayName": "Documents",
                  "fileLocation": {"WFFileLocationType": "Documents", "relativeSubpath": ""}}
        filename = "Toss Tap Pairing.txt"

        def begin_if(value):
            group = str(uuid4()).upper()
            add("conditional", "If", GroupingIdentifier=group, WFControlFlowMode=0, WFCondition=100,
                WFInput={"Type": "Variable", "Variable": variable(value)})
            return group

        def end_if(group):
            return add("conditional", "If Result", GroupingIdentifier=group, WFControlFlowMode=2)

        def load_configuration():
            stored = add("documentpicker.open", "Saved Toss Pairing", WFFile=folder,
                         WFGetFilePath=filename, WFFileErrorIfNotFound=False)
            return match(stored, PAIRING_PATTERN)

        stop_if(match(command, rf"\AToss(?:/setup/{CONFIGURATION})?\z"), 101)
        enrollment = match(command, rf"(?<=\AToss/setup/){CONFIGURATION}\z")

        selection = begin_if(enrollment)
        add("gettext", "New Toss Pairing", WFTextActionText=text(enrollment))
        add("conditional", "Otherwise", GroupingIdentifier=selection, WFControlFlowMode=1)
        load_configuration()
        configuration = end_if(selection)
        stop_if(configuration, 101, "请扫描 Mac 上 Toss 的配对码。\nScan the pairing code in Toss on your Mac.")

        mode = begin_if(enrollment)
        add("gettext", "Pair", WFTextActionText="/pair")
        add("conditional", "Otherwise", GroupingIdentifier=mode, WFControlFlowMode=1)
        add("gettext", "Capture", WFTextActionText="")
        suffix = end_if(mode)
        reply = request(configuration, suffix)
        check = add("gettext", "Response", WFTextActionText=text("Toss:", reply))

        completion = begin_if(enrollment)
        stop_if(check, 5, text("无法连接 Mac / Couldn't pair with the Mac.\n", reply), value="Toss:TOSS_PAIRED")
        add("documentpicker.save", "Save Toss Pairing", WFInput=variable(configuration), WFFolder=folder,
            WFSaveFileOverwrite=True, WFAskWhereToSave=False, WFFileDestinationPath=filename)
        saved = load_configuration()
        stop_if(saved, 101, "iPhone 无法读回配对信息。\nThe iPhone couldn't read back the pairing.")
        compare = add("gettext", "Compare Pairing", WFTextActionText=text(configuration, "\n", saved))
        stop_if(match(compare, r"\A([^\n]+)\n\1\z"), 101,
                "iPhone 保存的配对不一致。\nThe saved pairing did not match.")
        verified = request(saved, "/pair/complete")
        result = add("gettext", "Confirmation", WFTextActionText=text("Toss:", verified))
        stop_if(result, 5, text("配对未完成 / Pairing couldn't finish.\n", verified), value="Toss:TOSS_SETUP_COMPLETE")
        settings_url = add("url", "URL", WFURLActionURL=text(BACK_TAP_SETTINGS))
        add("openurl", "Open URLs", WFInput=variable(settings_url))
        add("nothing", "Nothing")
        add("exit", "Stop")
        end_if(completion)

        stop_if(check, 5, text("Mac 未完成请求 / Mac couldn't complete the request.\n", reply), value="Toss:")
        add("nothing", "Nothing")
    else:
        stop_if(match(command, r"\AToss(?:/authorize)?\z"), 101)
        # A missing match contributes an empty suffix. Only this fixed literal can
        # reach the URL, including when the caller passes unexpected shortcut input.
        suffix = match(command, r"(?<=\AToss)/authorize\z")

        configuration = match(setup_text, PAIRING_PATTERN)
        stop_if(configuration, 101,
                "请从 Mac 的 Toss 复制配对配置，重新添加此捷径，并在添加时粘贴。\n"
                "Copy the pairing setup from Toss on your Mac and paste it when adding this shortcut again.")
        response = request(configuration, suffix)
        # A successful capture or authorization has an empty response body.
        result = add("gettext", "Result", WFTextActionText=text("Toss:", response))
        stop_if(result, 5, text("Mac 未完成请求 / Mac couldn't complete the request.\n", response), value="Toss:")
        add("nothing", "Nothing")

    workflow = {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2600",
        "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": 59788, "WFWorkflowIconStartColor": 2071128575},
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowTypes": [],
    }
    if not phone_setup:
        workflow["WFWorkflowImportQuestions"] = [{
            "ActionIndex": 0,
            "Category": "Parameter",
            "ParameterKey": "WFTextActionText",
            "Text": "粘贴 Toss 复制的配置 / Paste setup from Toss",
            "DefaultValue": "",
        }]
    return workflow


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phone-setup", action="store_true", help="build the direct iPhone import")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_bytes(plistlib.dumps(make_shortcut("", args.phone_setup), fmt=plistlib.FMT_BINARY, sort_keys=False))
