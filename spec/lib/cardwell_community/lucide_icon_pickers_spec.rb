# frozen_string_literal: true

RSpec.describe CardwellCommunity::LucideIconPickers do
  fab!(:theme)

  # Stands in for the 306 Community theme's icons-sprite: two Lucide symbols
  # next to core's Font Awesome set. Synthetic, no real theme data.
  let(:custom_svgs) do
    {
      "lucide-house" =>
        '<symbol id="lucide-house" viewBox="0 0 24 24"><path d="M3 10l9-7 9 7"/></symbol>',
      "lucide-award" =>
        '<symbol id="lucide-award" viewBox="0 0 24 24"><circle cx="12" cy="8" r="6"/></symbol>',
    }
  end

  before do
    allow(SvgSprite).to receive(:custom_svgs).and_return(custom_svgs)
    SvgSprite.expire_cache
  end

  after { SvgSprite.expire_cache }

  def picker_ids(keyword = "")
    result =
      SvgSprite.icon_picker_search(keyword, false, page: 0, per_page: 5_000, theme_id: theme.id)
    result[:icons].map { |icon| icon[:id] }
  end

  it "offers only Lucide icons" do
    expect(picker_ids).to contain_exactly("lucide-award", "lucide-house")
  end

  it "still finds a Lucide icon by name" do
    expect(picker_ids("house")).to eq(["lucide-house"])
  end

  it "restores core's list when the part is turned off" do
    SiteSetting.cardwell_lucide_icon_pickers_enabled = false

    expect(picker_ids).to include("lucide-house", "heart")
  end

  it "restores core's list when the plugin is turned off" do
    # Turning the plugin off also makes part 0 publish core's compile limit on
    # its channel. Nothing resets the memory backlog between these specs, so
    # that message would outlive this example and break part 0's check of the
    # value published at boot.
    allow(CardwellCommunity::CompileTimeout).to receive(:broadcast!)
    SiteSetting.cardwell_community_enabled = false

    expect(picker_ids).to include("lucide-house", "heart")
  end

  it "leaves Font Awesome in the rendered sprite" do
    expect(SvgSprite.svgs_for(theme.id)).to include("heart")
  end
end
