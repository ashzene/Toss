// Generate the unsigned Mac and phone fixtures with scripts/make-iphone-shortcut.py.
// Run: osascript -l JavaScript Tests/IPhoneShortcutTemplateTests.js <fixture> [<fixture> ...]
ObjC.import("Foundation");
$.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/ActionKit.framework").load;

const registry = $.NSClassFromString("WFActionRegistry").sharedRegistry;
// A controller can deliver a final callback after the next fixture has started.
let observed;

ObjC.registerSubclass({
    name: "TossShortcutFixtureDelegate",
    superclass: "NSObject",
    methods: {
        "workflowController:actionDidRequestWorkflowExit:": {
            types: ["void", ["id", "id"]],
            implementation(controller, action) {
                if (observed.controller.isEqual(controller)) observed.requestedExit = true;
                controller.stop;
            },
        },
        "workflowController:didRunAction:error:": {
            types: ["void", ["id", "id", "id"]],
            implementation(controller, action, error) {
                if (!observed.controller.isEqual(controller)) return;
                if (!error.isNil()) observed.error = error;
                observed.visited.push(action.UUID.js);
                const output = action.output;
                if (!output.isNil()) {
                    const item = output.items.firstObject;
                    observed.outputs[action.UUID.js] = {
                        count: Number(output.numberOfItems),
                        itemClass: item.isNil() ? undefined : item.className.js,
                        text: !item.isNil() && item.respondsToSelector("string") ? item.string.js : undefined,
                    };
                }
            },
        },
        "workflowController:didFinishRunningWithError:cancelled:": {
            types: ["void", ["id", "id", "bool"]],
            implementation(controller, error, cancelled) {
                if (!observed.controller.isEqual(controller)) return;
                if (!error.isNil()) observed.error = error;
                observed.done = true;
            },
        },
    },
});

function check(truth, message) {
    if (!truth) throw new Error(message);
}

function actionFrom(definition) {
    return registry.createActionWithIdentifierSerializedParameters(
        definition.WFWorkflowActionIdentifier, $(definition.WFWorkflowActionParameters)
    );
}

function deserialize(template) {
    // Deserialize the file as Shortcuts does, so control-flow group boundaries
    // and migrated If conditions are reconstructed as a single action tree.
    const file = $.NSClassFromString("WFWorkflowFile").alloc.initWithDictionaryName($(template), "Toss tests");
    return $.NSClassFromString("WFWorkflow").alloc.initWithRecordReferenceStorageProviderError(
        file.recordRepresentationWithError(Ref()), undefined, undefined, Ref()
    );
}

function execute(definitions, input) {
    const workflow = deserialize({
        WFWorkflowActions: definitions, WFWorkflowClientVersion: "2600", WFWorkflowMinimumClientVersion: 900,
        WFWorkflowTypes: [], WFWorkflowInputContentItemClasses: ["WFStringContentItem"],
    });
    const controller = $.NSClassFromString("WFWorkflowController").new;
    const delegate = $.TossShortcutFixtureDelegate.new;
    const collection = $.NSClassFromString("WFContentCollection").new;
    if (input) collection.addObject($(input));
    observed = { controller, done: false, outputs: {}, visited: [] };
    controller.setDelegate(delegate);
    controller.setInput(collection);
    controller.setWorkflow(workflow);
    controller.run;
    const until = Date.now() + 5000;
    while (!observed.done && Date.now() < until) {
        $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.01));
    }
    if (!observed.done) controller.stop;
    check(observed.done, "Timed out running fixture");
    const hostExit = observed.requestedExit && observed.error?.domain.js === "NSPOSIXErrorDomain"
                     && Number(observed.error.code) === 7;
    if (observed.error && !hostExit) {
        const failure = new Error(observed.error.localizedDescription.js);
        failure.domain = observed.error.domain.js;
        failure.code = Number(observed.error.code);
        throw failure;
    }
    return observed.outputs;
}

function fixtureText(text, uuid) {
    return {
        WFWorkflowActionIdentifier: "is.workflow.actions.gettext",
        WFWorkflowActionParameters: { WFTextActionText: text, UUID: uuid },
    };
}

function testTemplate(template) {
    const actions = template.WFWorkflowActions;
    const parameters = def => def.WFWorkflowActionParameters;
    const uuid = def => parameters(def).UUID;
    const operation = def => def.WFWorkflowActionIdentifier.split("actions.")[1];
    const questions = deserialize(template).validImportQuestions;
    check(Number(questions.count) === 1 && questions.firstObject.parameter.key.js === "WFTextActionText",
          "Shortcuts must recognize one native text import question");
    const question = template.WFWorkflowImportQuestions[0];
    check(question.ActionIndex === 0 && question.DefaultValue === "" && operation(actions[0]) === "gettext" &&
          parameters(actions[0]).WFTextActionText === "", "Setup must be filled only at import time");
    check(template.WFWorkflowTypes.length === 0, "Back Tap should not request onscreen content");

    const permitted = new Set(["gettext", "text.match", "conditional", "alert", "nothing", "exit",
                               "text.split", "getitemfromlist", "hash", "downloadurl"]);
    const requests = actions.filter(def => operation(def) === "downloadurl");
    check(requests.length === 2 && !parameters(requests[0]).WFHTTPMethod &&
          parameters(requests[1]).WFHTTPMethod === "POST", "Both modes must share one GET and one POST");
    const postKeys = Object.keys(parameters(requests[1]));
    check(postKeys.every(key => ["WFHTTPMethod", "WFHTTPBodyType", "WFURL", "UUID"].includes(key)),
          "POST must not carry shortcut input in the body or headers");

    for (const def of actions) {
        check(permitted.has(operation(def)), "Unexpected dependency in Back Tap: " + operation(def));
        const action = actionFrom(def);
        const raw = parameters(def);
        for (let index = 0; index < action.parameters.count; index++) {
            const key = action.parameters.objectAtIndex(index).key.js;
            if (key in raw || (key === "WFConditions" && raw.WFControlFlowMode === 0)) {
                check(!action.parameterStateForKey(key).isNil(), def.WFWorkflowActionIdentifier + " dropped " + key);
            }
        }
    }

    const host = "http://fixture.local:54963";
    const config = host + "|" + "d".repeat(64);
    const nonce = "01234567-1234-1234-1234-123456789abc";
    const proof = "3ffab7d54142e501c80fb86b87215c71b930faa0bdfcab8011737bed96a62867";
    const get = host + "/toss/iphone/challenge";
    const post = host + "/toss/iphone/capture/" + nonce + "/" + proof;
    const cases = [
        {input: "", urls: [get, post]},
        {input: "/authorize", urls: [get + "/authorize", post]},
        {input: "/pair", urls: []},
        {input: "/authorize?text=untrusted", urls: []},
        {input: "https://example.test/screen-page", urls: []},
        {input: "Toss/authorize", urls: []},
        {input: "/AUTHORIZE", urls: []},
        {input: "/authorize\n", urls: []},
        {input: "", setup: config + "\n", urls: [get, post]},
        {input: "/authorize", setup: config + "\r\n", urls: [get + "/authorize", post]},
        {input: "", setup: "", urls: [], alert: true},
        {input: "/authorize", setup: "http://nothere.test:54963|" + "d".repeat(64), urls: [], alert: true},
        {input: "", setup: config + "\nextra", urls: [], alert: true},
        {input: "", challenge: "bad nonce", urls: [get], alert: true},
        {input: "", response: "TOSS_PAIRING_REQUIRED", urls: [get, post], alert: true},
    ];
    for (const test of cases) {
        // Substitute only effects. Use real URL parameters and the native
        // evaluator so a token serialization or branch error fails the test.
        const isolated = [];
        const urlIDs = [];
        const alertIDs = [];
        for (const def of actions) {
            if (def === actions[0]) {
                isolated.push(fixtureText(test.setup === undefined ? config : test.setup, uuid(def)));
            } else if (operation(def) === "downloadurl") {
                const urlID = $.NSUUID.UUID.UUIDString.js;
                urlIDs.push(urlID);
                isolated.push(fixtureText(parameters(def).WFURL, urlID));
                const reply = def === requests[0] ? (test.challenge || nonce) : (test.response || "");
                isolated.push(fixtureText(reply, uuid(def)));
            } else if (operation(def) === "alert") {
                alertIDs.push(uuid(def));
                isolated.push(fixtureText(parameters(def).WFAlertActionMessage, uuid(def)));
            } else {
                isolated.push(def);
            }
        }
        const results = execute(isolated, test.input);
        const actualURLs = urlIDs.filter(key => observed.visited.includes(key)).map(key => results[key].text);
        check(JSON.stringify(actualURLs) === JSON.stringify(test.urls), "Unexpected requests: " + JSON.stringify(actualURLs)
              + " for test " + JSON.stringify(test));
        const shownAlerts = alertIDs.filter(key => observed.visited.includes(key));
        check(shownAlerts.length === (test.alert ? 1 : 0), "Unexpected alert behavior for " + JSON.stringify(test));
        if (shownAlerts.length) check(results[shownAlerts[0]].text.length > 0, "Recovery prompt must be readable");
    }
    return cases.length;
}

function testQRTemplate(template) {
    const actions = template.WFWorkflowActions;
    const parameters = def => def.WFWorkflowActionParameters;
    const operation = def => def.WFWorkflowActionIdentifier.split("actions.")[1];
    const uuid = def => parameters(def).UUID;
    const readActions = actions.filter(def => operation(def) === "documentpicker.open");
    const requests = actions.filter(def => operation(def) === "downloadurl");
    const saveActions = actions.filter(def => operation(def) === "documentpicker.save");
    check(saveActions.length === 1, "Only enrollment saves its configuration");
    const saveAction = saveActions[0];
    const settingsActions = actions.filter(def => operation(def) === "openurl");
    check(settingsActions.length === 1 && !actionFrom(settingsActions[0]).parameterStateForKey("WFInput").isNil(),
          "The phone template needs one native Open URLs action");
    const openSettings = settingsActions[0];
    const doubleTapURL = "prefs:root=ACCESSIBILITY&path=TOUCH_REACHABILITY_TITLE/BackTap/DoubleTap";
    check(Number(deserialize(template).validImportQuestions.count) === 0, "QR setup must not ask for import answers");
    check(template.WFWorkflowTypes.length === 0, "Back Tap should not request onscreen content");
    check(readActions.length === 2 && requests.length === 4, "Expected shared request and setup-only confirmation");
    check(parameters(saveAction).WFAskWhereToSave === false && parameters(saveAction).WFSaveFileOverwrite === true,
          "Setup must use a fixed storage location");
    const pairingFile = parameters(saveAction).WFFileDestinationPath;
    check(pairingFile && !pairingFile.includes("/") && pairingFile !== "." &&
          parameters(saveAction).WFFolder.fileLocation.WFFileLocationType === "Documents" &&
          readActions.every(def => parameters(def).WFGetFilePath === pairingFile &&
                                   parameters(def).WFFile.fileLocation.WFFileLocationType === "Documents"),
          "Read the same device-local file directly at enrollment and capture");
    check(requests.every((def, index) => index % 2 === 0
          ? !parameters(def).WFHTTPMethod
          : parameters(def).WFHTTPMethod === "POST"), "Each challenge uses GET and each proof uses POST");
    const addr = "http://fixture.local:54963";
    const config = addr + "|" + "d".repeat(64);
    const setup = "/setup/" + config;
    const nonce = "01234567-1234-1234-1234-123456789abc";
    const proof = "3ffab7d54142e501c80fb86b87215c71b930faa0bdfcab8011737bed96a62867";
    const challenge = addr + "/toss/iphone/challenge";
    const post = addr + "/toss/iphone/capture/" + nonce + "/" + proof;
    const pair = [challenge + "/pair", post];
    const complete = [challenge + "/pair/complete", post];
    const cases = [
        { name: "background", config, urls: [challenge, post], reads: 1 },
        { name: "background missing", urls: [], reads: 1, alerts: 1 },
        { name: "pairing", input: setup, reply: "TOSS_PAIRED", reopened: config,
          urls: [...pair, ...complete], reads: 1, saves: 1, settings: true },
        { name: "pairing rejected", input: setup, reply: "TOSS_PAIRING_REQUIRED", urls: pair, alerts: 1 },
        { name: "could not save", input: setup, reply: "TOSS_PAIRED", urls: pair, reads: 1, saves: 1, alerts: 1 },
        { name: "wrong stored content", input: setup, reply: "TOSS_PAIRED", reopened: addr + "|" + "c".repeat(64),
          urls: pair, reads: 1, saves: 1, alerts: 1 },
        { name: "confirmation rejected", input: setup, reply: "TOSS_PAIRED", reopened: config,
          final: "TOSS_PAIRING_REQUIRED", urls: [...pair, ...complete], reads: 1, saves: 1, alerts: 1 },
        { name: "unexpected input", input: "https://outside.test", urls: [] },
        { name: "external host", input: setup.replace(".local", ".example"), urls: [] },
        { name: "trailing data", input: setup + "\n", urls: [] },
    ];
    for (const test of cases) {
        const rewritten = [];
        const urlIDs = [];
        for (const def of actions) {
            if (operation(def) === "downloadurl") {
                const id = $.NSUUID.UUID.UUIDString.js;
                urlIDs.push(id);
                rewritten.push(fixtureText(parameters(def).WFURL, id));
                const position = requests.indexOf(def);
                const response = [nonce, test.reply || "", nonce, test.final || "TOSS_SETUP_COMPLETE"][position];
                rewritten.push(fixtureText(response, uuid(def)));
            } else if (operation(def) === "documentpicker.open") {
                const value = def === readActions[0] ? test.config : test.reopened;
                rewritten.push(fixtureText(value || "", uuid(def)));
            } else if (operation(def) === "documentpicker.save") {
                const content = {WFSerializationType: "WFTextTokenString",
                                 Value: {string: "\ufffc", attachmentsByRange: {"{0, 1}": parameters(def).WFInput.Value}}};
                rewritten.push(fixtureText(content, uuid(def)));
            } else if (operation(def) === "alert") {
                rewritten.push(fixtureText(parameters(def).WFAlertActionMessage, uuid(def)));
            } else if (def === openSettings) {
                const link = {WFSerializationType: "WFTextTokenString",
                              Value: {string: "\ufffc", attachmentsByRange: {"{0, 1}": parameters(def).WFInput.Value}}};
                rewritten.push(fixtureText(link, uuid(def)));
            } else {
                rewritten.push(def);
            }
        }
        const outputs = execute(rewritten, test.input);
        const visited = def => observed.visited.includes(uuid(def));
        const urls = urlIDs.filter(id => observed.visited.includes(id)).map(id => outputs[id].text);
        check(JSON.stringify(urls) === JSON.stringify(test.urls), test.name + ": unexpected requests " + JSON.stringify(urls));
        check(readActions.filter(visited).length === (test.reads || 0), test.name + ": unexpected storage read");
        check(visited(saveAction) === Boolean(test.saves), test.name + ": unexpected storage write");
        if (test.saves) check(outputs[uuid(saveAction)].text === config, test.name + ": saved incorrect data");
        check(visited(openSettings) === Boolean(test.settings), test.name + ": unexpected Settings launch");
        if (test.settings) check(outputs[uuid(openSettings)].text === doubleTapURL, "Wrong Settings destination");
        const alerts = actions.filter(def => operation(def) === "alert").filter(visited);
        check(alerts.length === (test.alerts || 0), test.name + ": wrong error prompt");
    }
    return cases.length;
}

function run(argv) {
    check(argv.length > 0, "Pass one or more unsigned templates");
    const total = argv.reduce((count, path) => {
        const template = ObjC.deepUnwrap($.NSDictionary.dictionaryWithContentsOfFile(path));
        check(template && Array.isArray(template.WFWorkflowActions), "Could not load shortcut fixture: " + path);
        const hasImportQuestion = (template.WFWorkflowImportQuestions?.length ?? 0) > 0;
        return count + (hasImportQuestion ? testTemplate(template) : testQRTemplate(template));
    }, 0);
    return "Apple Shortcuts passed " + total + " offline workflow cases.";
}
