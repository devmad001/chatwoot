# == Schema Information
#
# Table name: articles
#
#  id                    :bigint           not null, primary key
#  content               :text
#  description           :text
#  meta                  :jsonb
#  position              :integer
#  slug                  :string           not null
#  status                :integer
#  title                 :string
#  views                 :integer
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :integer          not null
#  associated_article_id :bigint
#  author_id             :bigint
#  category_id           :integer
#  folder_id             :integer
#  portal_id             :integer          not null
#
# Indexes
#
#  index_articles_on_associated_article_id  (associated_article_id)
#  index_articles_on_author_id              (author_id)
#  index_articles_on_slug                   (slug) UNIQUE
#
class Article < ApplicationRecord
  include PgSearch::Model

  has_many :associated_articles,
           class_name: :Article,
           foreign_key: :associated_article_id,
           dependent: :nullify,
           inverse_of: 'root_article'

  has_many :article_embeddings, dependent: :destroy

  belongs_to :root_article,
             class_name: :Article,
             foreign_key: :associated_article_id,
             inverse_of: :associated_articles,
             optional: true
  belongs_to :account
  belongs_to :category, optional: true
  belongs_to :portal
  belongs_to :author, class_name: 'User', inverse_of: :articles

  before_validation :ensure_account_id
  before_validation :ensure_article_slug

  validates :account_id, presence: true
  validates :author_id, presence: true
  validates :title, presence: true
  validates :content, presence: true

  # ensuring that the position is always set correctly
  before_create :add_position_to_article
  after_save :category_id_changed_action, if: :saved_change_to_category_id?

  after_save :add_article_embedding, if: -> { saved_change_to_title? || saved_change_to_description? || saved_change_to_content? }

  enum status: { draft: 0, published: 1, archived: 2 }

  scope :search_by_category_slug, ->(category_slug) { where(categories: { slug: category_slug }) if category_slug.present? }
  scope :search_by_category_locale, ->(locale) { where(categories: { locale: locale }) if locale.present? }
  scope :search_by_author, ->(author_id) { where(author_id: author_id) if author_id.present? }
  scope :search_by_status, ->(status) { where(status: status) if status.present? }
  scope :order_by_updated_at, -> { reorder(updated_at: :desc) }
  scope :order_by_position, -> { reorder(position: :asc) }
  scope :order_by_views, -> { reorder(views: :desc) }

  # TODO: if text search slows down https://www.postgresql.org/docs/current/textsearch-features.html#TEXTSEARCH-UPDATE-TRIGGERS
  pg_search_scope(
    :text_search,
    against: %i[
      title
      description
      content
    ],
    using: {
      tsearch: {
        prefix: true
      }
    }
  )

  def self.vector_search(params)
    embedding = Openai::EmbeddingsService.new.get_embedding(params['query'])
    records = joins(
      :category
    ).search_by_category_slug(
      params[:category_slug]
    ).search_by_category_locale(params[:locale]).search_by_author(params[:author_id]).search_by_status(params[:status])
    filtered_article_ids = records.pluck(:id)

    # Fetch nearest neighbors and their distances, then filter directly

    # experimenting with filtering results based on result threshold
    # distance_threshold = 0.2
    # if using add the filter block to the below query
    # .filter { |ae| ae.neighbor_distance <= distance_threshold }

    article_ids = ArticleEmbedding.where(article_id: filtered_article_ids)
                                  .nearest_neighbors(:embedding, embedding, distance: 'cosine')
                                  .limit(5)
                                  .pluck(:article_id)

    # Fetch the articles by the IDs obtained from the nearest neighbors search
    where(id: article_ids)
  end

  def add_article_embedding
    terms = generate_article_search_terms
    article_embeddings.destroy_all
    terms.each do |term|
      article_embeddings.create!(term: term)
    end
  end

  def article_prompt
    <<~SYSTEM_PROMPT_MESSAGE
      For the provided article content, generate potential search query keywords and snippets that can be used to generate the embeddings.

      Ensure the search terms are as diverse as possible but capture the essence of the article and are super related to the articles. Don't return any terms if there aren't any terms of relevance.

      Always return results in valid JSON of the following format

      {#{'  '}
      "search_terms": []#{' '}
      }
    SYSTEM_PROMPT_MESSAGE
  end

  def generate_article_search_terms
    messages = [
      { role: 'system', content: article_prompt },
      { role: 'user', content: "title: #{title} \n content: #{content}" }
    ]
    headers = { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{ENV.fetch('OPENAI_API_KEY')}" }
    body = { model: 'gpt-4-turbo', messages: messages, response_format: { type: 'json_object' } }.to_json
    Rails.logger.info "Requesting Chat GPT with body: #{body}"
    response = HTTParty.post('https://api.openai.com/v1/chat/completions', headers: headers, body: body)
    Rails.logger.info "Chat GPT response: #{response.body}"
    JSON.parse(response.body)
    JSON.parse(response.parsed_response['choices'][0]['message']['content'])['search_terms']
  end

  def self.search(params)
    records = joins(
      :category
    ).search_by_category_slug(
      params[:category_slug]
    ).search_by_category_locale(params[:locale]).search_by_author(params[:author_id]).search_by_status(params[:status])

    records = records.text_search(params[:query]) if params[:query].present?
    records
  end

  def associate_root_article(associated_article_id)
    article = portal.articles.find(associated_article_id) if associated_article_id.present?

    return if article.nil?

    root_article_id = self.class.find_root_article_id(article)

    update(associated_article_id: root_article_id) if root_article_id.present?
  end

  # Make sure we always associate the parent's associated id to avoid the deeper associations od articles.
  def self.find_root_article_id(article)
    article.associated_article_id || article.id
  end

  def draft!
    update(status: :draft)
  end

  def increment_view_count
    # rubocop:disable Rails/SkipsModelValidations
    update_column(:views, views? ? views + 1 : 1)
    # rubocop:enable Rails/SkipsModelValidations
  end

  def self.update_positions(positions_hash)
    positions_hash.each do |article_id, new_position|
      # Find the article by its ID and update its position
      article = Article.find(article_id)
      article.update!(position: new_position)
    end
  end

  private

  def category_id_changed_action
    # We need to update the position of the article in the new category
    return unless persisted?

    # this means the article is just created
    # and the category_id is newly set
    # and the position is already present
    return if created_at_before_last_save.nil? && position.present? && category_id_before_last_save.nil?

    update_article_position_in_category
  end

  def add_position_to_article
    # on creation if a position is already present, ignore it
    return if position.present?

    update_article_position_in_category
  end

  def update_article_position_in_category
    max_position = Article.where(category_id: category_id, account_id: account_id).maximum(:position)

    new_position = max_position.present? ? max_position + 10 : 10

    # update column to avoid validations if the article is already persisted
    if persisted?
      # rubocop:disable Rails/SkipsModelValidations
      update_column(:position, new_position)
      # rubocop:enable Rails/SkipsModelValidations
    else
      self.position = new_position
    end
  end

  def ensure_account_id
    self.account_id = portal&.account_id
  end

  def ensure_article_slug
    self.slug ||= "#{Time.now.utc.to_i}-#{title.underscore.parameterize(separator: '-')}" if title.present?
  end
end
