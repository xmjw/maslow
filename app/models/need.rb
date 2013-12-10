require "active_model"

class Need
  extend ActiveModel::Naming
  include ActiveModel::Validations
  include ActiveModel::Conversion
  include ActiveModel::Serialization

  class NotFound < StandardError
    attr_reader :need_id

    def initialize(need_id)
      super("Need with ID #{need_id} not found")
      @need_id = need_id
    end
  end

  JUSTIFICATIONS = [
    "It's something only government does",
    "The government is legally obliged to provide it",
    "It's inherent to a person's or an organisation's rights and obligations",
    "It's something that people can do or it's something people need to know before they can do something that's regulated by/related to government",
    "There is clear demand for it from users",
    "It's something the government provides/does/pays for",
    "It's straightforward advice that helps people to comply with their statutory obligations"
  ]
  IMPACT = [
    "No impact",
    "Noticed only by an expert audience",
    "Noticed by the average member of the public",
    "Has consequences for the majority of your users",
    "Has serious consequences for your users and/or their customers",
    "Endangers people"
  ]
  NUMERIC_FIELDS = ["yearly_user_contacts", "yearly_site_views", "yearly_need_views", "yearly_searches"]
  FIELDS = ["role", "goal", "benefit", "organisation_ids", "impact", "justifications", "met_when",
    "other_evidence", "legislation"] + NUMERIC_FIELDS

  # list non-writable fields returned from the API which we want to make accessible
  READ_ONLY_FIELDS = [ :id, :revisions, :organisations, :applies_to_all_organisations ]

  attr_accessor *FIELDS
  attr_reader *READ_ONLY_FIELDS

  alias_method :need_id, :id

  validates_presence_of ["role", "goal", "benefit"]
  validates :impact, inclusion: { in: IMPACT }, allow_blank: true
  validates_each :justifications do |record, attr, value|
    record.errors.add(attr, "must contain a known value") unless (value.nil? || value.all? { |v| JUSTIFICATIONS.include? v })
  end
  NUMERIC_FIELDS.each do |field|
    validates_numericality_of field, :only_integer => true, :allow_blank => true, :greater_than_or_equal_to => 0
  end

  # Retrieve a need from the Need API, or raise NotFound if it doesn't exist.
  #
  # This works in roughly the same way as an ActiveRecord-style `find` method,
  # just with a different exception type.
  def self.find(need_id)
    need_response = Maslow.need_api.need(need_id)
    if need_response
      # Discard fields from the API we don't understand. Coupling the fields
      # this app understands to the fields it expects from clients is fine, but
      # we don't want to couple that with the fields we can use in the API.
      accepted_fields = need_response.to_hash.with_indifferent_access.slice( *(FIELDS + READ_ONLY_FIELDS) )
      self.new(accepted_fields, true)
    else
      raise NotFound, need_id
    end
  end

  def initialize(attrs, existing = false)
    filtered_attributes = assign_and_filter_values(attrs)# if existing

    @existing = existing
    update(filtered_attributes)
  end

  def add_more_criteria
    @met_when << ""
  end

  def remove_criteria(index)
    @met_when.delete_at(index)
  end

  def update(attrs)
    strip_newline_from_textareas(attrs)

    unless (attrs.keys - FIELDS).empty?
      raise(ArgumentError, "Unrecognised attributes present in: #{attrs.keys}")
    end
    attrs.keys.each do |f|
      send("#{f}=", attrs[f])
    end
    @met_when ||= []
    @justifications ||= []
  end

  def artefacts
    @artefacts ||= Maslow.content_api.for_need(@id)
  rescue GdsApi::BaseError
    []
  end

  def as_json(options = {})
    # Build up the hash manually, as ActiveModel::Serialization's default
    # behaviour serialises all attributes, including @errors and
    # @validation_context.
    remove_blank_met_when_criteria
    res = (FIELDS + NUMERIC_FIELDS).each_with_object({}) do |field, hash|
      if value = send(field) and value.present?


        # if this is a numeric field, force the value we send to the API to be an
        # integer
        value = Integer(value) if NUMERIC_FIELDS.include?(field)
      end

      hash[field] = value
    end
  end

  def save
    raise("The save_as method must be used when persisting a need, providing details about the author.")
  end

  def save_as(author)
    atts = as_json.merge("author" => {
      "name" => author.name,
      "email" => author.email,
      "uid" => author.uid
    })

    if persisted?
      Maslow.need_api.update_need(@id, atts)
    else
      response_hash = Maslow.need_api.create_need(atts).to_hash
      @existing = true
      filtered_values = assign_and_filter_values(response_hash)
      update(filtered_values)
    end
    true
  rescue GdsApi::HTTPErrorResponse => err
    false
  end

  def persisted?
    @existing
  end

private
  def assign_and_filter_values(original_attrs)
    attrs = original_attrs.except("_response_info")

    # map the read only fields from the API to instance variables of
    # the same name
    READ_ONLY_FIELDS.map(&:to_s).each do |field|
      value = attrs.delete(field)
      prepared_value = case field
                       when 'revisions'
                         prepare_revisions(value)
                       when 'organisations'
                         prepare_organisations(value)
                       else
                         value
                       end

      instance_variable_set("@#{field}", prepared_value)
    end
    attrs
  end

  def prepare_organisations(organisations)
    return [] unless organisations.present?
    GdsApi::Response.build_ostruct_recursively(organisations)
  end

  def prepare_revisions(revisions)
    return [] unless revisions.present?

    structs = GdsApi::Response.build_ostruct_recursively(revisions)

    # Return changes as a hash, rather than an OpenStruct because
    # we would like changes to be returned as field-value pairs
    structs.each_with_index do |revision, i|
      revision.changes = revisions[i]["changes"]
    end
  end

  def remove_blank_met_when_criteria
    if met_when
      met_when.delete_if(&:empty?)
    end
  end

  def strip_newline_from_textareas(attrs)
    # Rails prepends a newline character into the textarea fields in the form.
    # Strip these so that we don't send them to the Need API.
    ["legislation", "other_evidence"].each do |field|
      attrs[field].sub!(/\A\n/, "") if attrs[field].present?
    end
  end
end
