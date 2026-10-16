# frozen_string_literal: true

# Part 3 (306-498): one row per member, day and source. See VisitSource.
class CreateCardwellVisitSources < ActiveRecord::Migration[8.0]
  def change
    create_table :cardwell_visit_sources do |t|
      t.integer :user_id, null: false
      t.date :visited_at, null: false
      t.string :source, null: false, limit: 20
      t.datetime :created_at, null: false
    end

    add_index :cardwell_visit_sources,
              %i[user_id visited_at source],
              unique: true,
              name: "idx_cardwell_visit_sources_unique"

    # Deleting an account deletes its rows.
    add_foreign_key :cardwell_visit_sources, :users, on_delete: :cascade
  end
end
