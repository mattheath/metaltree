class GumtreeProperty
  include Dynamoid::Document

  table :name => :gumtree_properties, :key => :gumtree_id

  field :gumtree_id
  field :property_id
end
