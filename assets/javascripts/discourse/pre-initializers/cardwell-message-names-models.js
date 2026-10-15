import { withPluginApi } from "discourse/lib/plugin-api";
import { activityKey, activityNames } from "../lib/cardwell-activity-names";

// Part 1 (306-535). Model fields and callbacks have to be registered before a
// model is first looked up, so they live in a pre-initializer.
export default {
  name: "cardwell-message-names-models",
  before: "inject-discourse-objects",

  initialize() {
    withPluginApi((api) => {
      // Post declares its fields, so one a plugin sends has to be registered
      // to reach the model.
      api.addModelField("post", "action_code_who_name");

      api.addModelCallback("user-action", "init", function () {
        if (this.action_code_who && this.action_code_who_name) {
          activityNames.set(
            activityKey(this.action_code, this.action_code_who),
            this.action_code_who_name,
          );
        }
      });
    });
  },
};
