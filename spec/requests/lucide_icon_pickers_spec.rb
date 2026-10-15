# frozen_string_literal: true

RSpec.describe "Lucide icon pickers: picker-search caching" do
  fab!(:admin)

  before { sign_in(admin) }

  # A browser that cached the list under one setting must refetch it after a
  # toggle, or the picker keeps showing the old set until the core version or
  # sprite changes.
  it "changes the ETag when the part is toggled" do
    get "/svg-sprite/picker-search.json"
    expect(response.status).to eq(200)
    etag_on = response.headers["ETag"]

    SiteSetting.cardwell_lucide_icon_pickers_enabled = false
    get "/svg-sprite/picker-search.json", headers: { "If-None-Match" => etag_on }

    expect(response.status).to eq(200)
    expect(response.headers["ETag"]).not_to eq(etag_on)
  end
end
