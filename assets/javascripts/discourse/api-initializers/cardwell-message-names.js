import { action } from "@ember/object";
import { trustHTML } from "@ember/template";
import { ajax } from "discourse/lib/ajax";
import { apiInitializer } from "discourse/lib/api";
import { userPath } from "discourse/lib/url";
import { escapeExpression } from "discourse/lib/utilities";
import { i18n } from "discourse-i18n";
import { activityKey, activityNames } from "../lib/cardwell-activity-names";

// Part 1 (306-535), the browser half. Core builds three lines from a person's
// handle with no hook to swap in their name: the screen-reader heading on a
// message's history notice, the activity stream line ("invited @dana") and the
// composer's "hasn't been seen in a while" warning. The server sends the names
// (lib/cardwell_community/message_names.rb); each override below takes core's
// own output and swaps the handle for the name, so core's wording, links and
// dates stay as they are, and everything falls back to the handle when no name
// came (the part is off, or the person has no name).

// Core writes the handle as link text, ">@handle<", escaped. A replacer
// function, so a "$" in a name is inserted as is rather than read as a
// replacement pattern.
function swapLinkText(html, handle, name) {
  return html.replace(
    `>@${escapeExpression(handle)}<`,
    () => `>${escapeExpression(name)}<`,
  );
}

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");

  // 1. The notice's hidden heading, read aloud before the row: core builds it
  // from "@handle" in small-action.gjs.
  api.modifyClass(
    "component:post/small-action",
    (Superclass) =>
      class extends Superclass {
        get a11yHeadingText() {
          const text = super.a11yHeadingText;
          const name = this.args.post?.action_code_who_name;
          return name && this.who
            ? text.replace(`@${this.who}`, () => name)
            : text;
        }
      },
  );

  // 2. Activity stream rows: names collected as the rows are built (see
  // ../pre-initializers/cardwell-message-names-models.js).
  api.modifyClass(
    "component:post-action-description",
    (Superclass) =>
      class extends Superclass {
        get description() {
          const html = super.description;
          const name = activityNames.get(
            activityKey(this.args.actionCode, this.args.username),
          );
          return html && name
            ? trustHTML(swapLinkText(html.toString(), this.args.username, name))
            : html;
        }
      },
  );

  // 3. The composer warning. Core asks the server which recipients haven't
  // been seen in a while, then builds "@handle" links inside one long method;
  // rather than copy that method, this asks again once the warning shows (the
  // server's answer now carries names) and rewrites the body. The warning is
  // rare: it needs a recipient who hasn't visited in months.
  api.modifyClass(
    "component:composer-messages",
    (Superclass) =>
      class extends Superclass {
        @action
        popup(message) {
          super.popup(message);
          // Only when the part could send names: otherwise the second
          // request would come back without them.
          if (
            message?.id === "user-not-seen" &&
            siteSettings.cardwell_message_names_enabled &&
            siteSettings.enable_names &&
            this.messages.includes(message)
          ) {
            this.cardwellNameNotSeen(message);
          }
        }

        async cardwellNameNotSeen(message) {
          let response;
          try {
            response = await ajax(
              "/composer_messages/user_not_seen_in_a_while",
              {
                data: { usernames: this.recipientNames },
              },
            );
          } catch {
            return;
          }
          if (
            this.isDestroying ||
            !response?.names ||
            !this.messages.includes(message)
          ) {
            return;
          }

          const links = response.usernames.map(
            (username, index) =>
              `<a class='mention' href='${userPath(username)}'>${escapeExpression(response.names[index])}</a>`,
          );
          const key =
            response.user_count === 1
              ? "composer.user_not_seen_in_a_while.single"
              : "composer.user_not_seen_in_a_while.multiple";
          message.set(
            "body",
            i18n(key, {
              usernames: links.join(", "),
              time_ago: response.time_ago,
            }),
          );
        }
      },
  );
});
