# frozen_string_literal: true

RSpec.describe "Visit source (part 3)" do
  fab!(:member, :user)

  before { SiteSetting.cardwell_visit_source_enabled = true }

  def sources(user = member)
    DB.query_single(
      "SELECT source FROM cardwell_visit_sources WHERE user_id = :id ORDER BY source",
      id: user.id,
    )
  end

  context "when signed in" do
    before { sign_in(member) }

    it "records a tagged arrival and sends the member on without the tag" do
      get "/latest?cw_src=digest"

      expect(response).to redirect_to("/latest")
      expect(sources).to eq(["digest"])
    end

    it "keeps the rest of the query when it drops the tag" do
      get "/latest?order=activity&cw_src=notification"

      expect(response).to redirect_to("/latest?order=activity")
    end

    it "doesn't count the clean address it lands on as a direct visit" do
      get "/latest?cw_src=digest"
      get "/latest"

      expect(response.status).to eq(200)
      expect(sources).to eq(["digest"])
    end

    # The landed cookie lasts a minute; clearing it stands in for coming back
    # later.
    def later!
      cookies.delete(CardwellCommunity::VisitSource::LANDED_COOKIE)
    end

    it "records a later visit on their own the same day" do
      get "/latest?cw_src=digest"
      get "/latest"
      later!
      get "/categories"

      expect(sources).to eq(%w[digest direct])
    end

    it "keeps one row per source per day" do
      get "/latest?cw_src=push"
      get "/latest?cw_src=push"
      later!
      get "/categories"
      get "/categories"

      expect(sources).to eq(%w[direct push])
    end

    it "dates rows with the server's UTC day, as user_visits does" do
      freeze_time Time.utc(2026, 10, 20, 23, 30)

      get "/latest?cw_src=digest"

      expect(
        DB.query_single(
          "SELECT visited_at FROM cardwell_visit_sources WHERE user_id = ?",
          member.id,
        ),
      ).to eq([Date.new(2026, 10, 20)])
    end

    it "ignores a value it doesn't know, and leaves the address alone" do
      get "/latest?cw_src=newsletter"

      expect(response.status).to eq(200)
      expect(sources).to eq(["direct"])
    end

    it "doesn't record JSON and background requests" do
      get "/latest.json?cw_src=digest"
      get "/latest", xhr: true

      expect(sources).to be_empty
    end

    it "doesn't count a page that isn't a visit" do
      get "/offline.html"

      expect(response.status).to eq(200)

      expect(sources).to be_empty
    end

    it "doesn't count a fetch the browser says isn't a page, like the service worker's" do
      get "/latest", headers: { "Sec-Fetch-Dest" => "empty" }
      get "/latest?cw_src=digest", headers: { "Sec-Fetch-Dest" => "iframe" }

      expect(response.status).to eq(200)
      expect(sources).to be_empty
    end

    it "doesn't count a page opened from a link inside the community" do
      get "/latest", headers: { "Sec-Fetch-Dest" => "document", "Sec-Fetch-Site" => "same-origin" }

      expect(sources).to be_empty
    end

    it "lands every email link opened at once cleanly" do
      get "/latest?cw_src=digest"
      get "/latest?cw_src=notification"
      get "/latest"
      get "/categories"

      expect(sources).to eq(%w[digest notification])
    end

    it "counts a page the browser says is a top-level page" do
      get "/latest", headers: { "Sec-Fetch-Dest" => "document" }

      expect(sources).to eq(["direct"])
    end

    it "records nothing while the setting is off" do
      SiteSetting.cardwell_visit_source_enabled = false

      get "/latest?cw_src=digest"

      expect(response.status).to eq(200)
      expect(sources).to be_empty
    end

    it "records nothing while the plugin is off" do
      # Turning the plugin off also makes part 0 publish core's compile limit on
      # its channel, which would outlive this example and break part 0's check of
      # the value published at boot.
      allow(CardwellCommunity::CompileTimeout).to receive(:broadcast!)
      SiteSetting.cardwell_community_enabled = false

      get "/latest?cw_src=digest"

      expect(response.status).to eq(200)
      expect(sources).to be_empty
    end
  end

  context "when signed out" do
    it "records nothing and leaves the tag for after sign-in" do
      get "/latest?cw_src=digest"

      expect(response.status).to eq(200)
      expect(DB.query_single("SELECT COUNT(*) FROM cardwell_visit_sources").first).to eq(0)
    end

    it "keeps the tag through the login redirect" do
      SiteSetting.login_required = true

      get "/latest?cw_src=digest"

      expect(response).to redirect_to("/login")
      expect(CGI.unescape(cookies[:destination_url].to_s)).to include("cw_src=digest")
    end
  end

  it "deletes a member's rows with their account" do
    sign_in(member)
    get "/latest?cw_src=digest"

    UserDestroyer.new(Discourse.system_user).destroy(member)

    expect(DB.query_single("SELECT COUNT(*) FROM cardwell_visit_sources").first).to eq(0)
  end
end
