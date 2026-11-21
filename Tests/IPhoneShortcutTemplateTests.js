// Generate the unsigned Mac and phone fixtures with scripts/make-iphone-shortcut.py.
// Run: osascript -l JavaScript Tests/IPhoneShortcutTemplateTests.js <fixture> [<fixture> ...]
ObjC.import("Foundation");
$.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/ActionKit.framework").load;

const registry = $.NSClassFromString("WFActionRegistry").sharedRegistry;
let observed;

ObjC.registerSubclass({
    name: "TossShortcutFixtureDelegate",
    superclass: "NSObject",
    methods: {
        "workflowController:actionDidRequestWorkflowExit:": {
            types: ["void", ["id", "id"]],
            implementation(controller, action) {
                observed.requestedExit = true;
                controller.stop;
            },
        },
        "workflowController:didRunAction:error:": {
            types: ["void", ["id", "id", "id"]],
            implementation(controller, action, error) {
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
    observed = { done: false, outputs: {}, visited: [] };
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

function testTemplate(path) {
    const template = ObjC.deepUnwrap($.NSDictionary.dictionaryWithContentsOfFile(path));
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

function run(argv) {
    check(argv.length > 0, "Pass one or more unsigned templates");
    const total = argv.reduce((count, path) => count + testTemplate(path), 0);
    return "Apple Shortcuts recognized the text setup and passed " + total + " offline workflow cases.";
}
