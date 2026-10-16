# frozen_string_literal: true

RSpec.describe CardwellCommunity::VisitSource do
  fab!(:user)

  let(:base) { Discourse.base_url }

  before { SiteSetting.cardwell_visit_source_enabled = true }

  def email(html:, text:)
    message = Mail::Message.new
    message.html_part =
      Mail::Part.new do
        content_type "text/html; charset=UTF-8"
        body html
      end
    message.text_part =
      Mail::Part.new do
        content_type "text/plain; charset=UTF-8"
        body text
      end
    message
  end

  def hrefs(message)
    Nokogiri::HTML5.parse(message.html_part.decoded).css("a[href]").map { |link| link["href"] }
  end

  describe ".email_source" do
    it "names the summary and notification emails, and nothing else" do
      expect(described_class.email_source(:digest)).to eq("digest")
      expect(described_class.email_source("user_replied")).to eq("notification")
      expect(described_class.email_source(:mailing_list)).to eq("notification")
      expect(described_class.email_source("forgot_password")).to be_nil
      expect(described_class.email_source(:email_login)).to be_nil
      expect(described_class.email_source(:invite)).to be_nil
    end
  end

  describe ".append" do
    it "adds the tag to a bare path, after a query and before a fragment" do
      expect(described_class.append("/t/hello/12", "push")).to eq("/t/hello/12?cw_src=push")
      expect(described_class.append("/t/hello/12?u=dana", "digest")).to eq(
        "/t/hello/12?u=dana&cw_src=digest",
      )
      expect(described_class.append("/t/hello/12/3#reply", "digest")).to eq(
        "/t/hello/12/3?cw_src=digest#reply",
      )
    end

    it "leaves a link that already has a tag" do
      expect(described_class.append("/latest?cw_src=invite", "digest")).to eq(
        "/latest?cw_src=invite",
      )
    end
  end

  describe ".tag_email" do
    let(:message) { email(html: <<~HTML, text: <<~TEXT) }
          <html><body>
            <a href="#{base}/t/hello/12/3">Visit</a>
            <a href="#{base}/t/hello/12?u=dana&amp;x=1">Shared</a>
            <a href="https://example.com/article">Elsewhere</a>
            <a href="#{base}/email/unsubscribe/abc123">Unsubscribe</a>
            <a href="#{base}/uploads/default/original/1X/a.pdf">File</a>
            <a href="mailto:collective@cardwellgroup.com">Write to us</a>
          </body></html>
        HTML
          Read it here: #{base}/t/hello/12/3.
          [Visit Topic](#{base}/t/hello/12/3)
          Elsewhere: https://example.com/article
          Unsubscribe: #{base}/email/unsubscribe/abc123
        TEXT

    it "tags the community's own links in a summary email" do
      described_class.tag_email(message, :digest)

      expect(hrefs(message)).to eq(
        [
          "#{base}/t/hello/12/3?cw_src=digest",
          "#{base}/t/hello/12?u=dana&x=1&cw_src=digest",
          "https://example.com/article",
          "#{base}/email/unsubscribe/abc123",
          "#{base}/uploads/default/original/1X/a.pdf",
          "mailto:collective@cardwellgroup.com",
        ],
      )

      text = message.text_part.decoded.gsub("\r\n", "\n")
      expect(text).to include("Read it here: #{base}/t/hello/12/3?cw_src=digest.")
      expect(text).to include("[Visit Topic](#{base}/t/hello/12/3?cw_src=digest)")
      expect(text).to include("Elsewhere: https://example.com/article\n")
      expect(text).to include("Unsubscribe: #{base}/email/unsubscribe/abc123\n")
    end

    it "tags notification emails as notification" do
      described_class.tag_email(message, "user_mentioned")

      expect(hrefs(message).first).to eq("#{base}/t/hello/12/3?cw_src=notification")
    end

    it "leaves account emails alone" do
      described_class.tag_email(message, :forgot_password)

      expect(hrefs(message).first).to eq("#{base}/t/hello/12/3")
    end

    it "leaves every email alone while the setting is off" do
      SiteSetting.cardwell_visit_source_enabled = false

      described_class.tag_email(message, :digest)

      expect(hrefs(message).first).to eq("#{base}/t/hello/12/3")
    end

    it "runs on Discourse's before_email_send" do
      DiscourseEvent.trigger(:before_email_send, message, :user_replied)

      expect(hrefs(message).first).to eq("#{base}/t/hello/12/3?cw_src=notification")
    end

    it "keeps non-ASCII text intact" do
      message = email(html: "<p>Zoë’s <a href=\"#{base}/t/x/1\">ask</a></p>", text: "Zoë’s ask")

      described_class.tag_email(message, :digest)

      expect(message.html_part.decoded).to include("Zoë’s")
      expect(message.text_part.decoded).to eq("Zoë’s ask")
    end
  end

  describe ".without_param" do
    it "drops only the tag" do
      expect(described_class.without_param("/latest?cw_src=digest")).to eq("/latest")
      expect(described_class.without_param("/t/x/1?u=dana&cw_src=push&page=2")).to eq(
        "/t/x/1?u=dana&page=2",
      )
    end

    it "drops an encoded tag too, so the redirect can't loop" do
      expect(described_class.without_param("/latest?cw%5Fsrc=digest&a=1")).to eq("/latest?a=1")
    end

    it "always stays on this site" do
      expect(described_class.without_param("//example.com/x?cw_src=digest")).to eq("/example.com/x")
      expect(described_class.without_param("/\\example.com?cw_src=digest")).to eq("/example.com")
    end
  end

  describe "web push" do
    let(:payload) do
      {
        notification_type: Notification.types[:replied],
        post_url: "/t/hello/12/3",
        topic_id: 12,
        excerpt: "A reply",
        username: "dana",
        translated_title: "Dana replied",
      }
    end

    it "tags the link a push notification opens" do
      message = PushNotificationPusher.push(user, payload)

      expect(message[:url]).to eq("/t/hello/12/3?cw_src=push")
    end

    it "leaves it untagged while the setting is off" do
      SiteSetting.cardwell_visit_source_enabled = false

      message = PushNotificationPusher.push(user, payload)

      expect(message[:url]).to eq("/t/hello/12/3")
    end
  end
end
