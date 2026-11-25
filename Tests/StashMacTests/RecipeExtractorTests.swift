import Foundation
import Testing

@testable import StashMac

@Test func testDecodeRecipeDataWithConvertFromSnakeCase() throws {
    let json = """
    {
        "title": "Neapolitan Pizza Dough",
        "description": "Authentic crispy pizza crust.",
        "image_url": "https://example.com/pizza.jpg",
        "author": "Chef Mario",
        "source_url": "https://example.com/recipe",
        "yield": "2-3 dough balls",
        "prep_time": "15 mins",
        "cook_time": "10 mins",
        "total_time": "25 mins",
        "category": "Baking",
        "cuisine": "Italian",
        "ingredients": [
            {"text": "500g Tipo 00 flour", "section": "Dough"},
            {"text": "325ml warm water", "section": "Dough"}
        ],
        "instructions": [
            {"step_number": 1, "title": "Mix", "text": "Mix flour and water.", "section": "Dough"},
            {"step_number": 2, "text": "Knead for 10 minutes."}
        ],
        "nutrition": {
            "calories": "250 kcal"
        }
    }
    """

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let recipe = try decoder.decode(RecipeData.self, from: Data(json.utf8))

    #expect(recipe.title == "Neapolitan Pizza Dough")
    #expect(recipe.imageURL == "https://example.com/pizza.jpg")
    #expect(recipe.sourceURL == "https://example.com/recipe")
    #expect(recipe.prepTime == "15 mins")
    #expect(recipe.cookTime == "10 mins")
    #expect(recipe.totalTime == "25 mins")
    #expect(recipe.ingredients.count == 2)
    #expect(recipe.ingredients[0].text == "500g Tipo 00 flour")
    #expect(recipe.instructions.count == 2)
    #expect(recipe.instructions[0].stepNumber == 1)
    #expect(recipe.instructions[0].title == "Mix")
    #expect(recipe.instructions[1].stepNumber == 2)
    #expect(recipe.nutrition?["calories"] == "250 kcal")
}

@Test func testExtractJSONLDRecipe() throws {
    let html = """
    <!DOCTYPE html>
    <html>
    <head>
        <script type="application/ld+json">
        {
            "@context": "https://schema.org",
            "@graph": [
                {
                    "@type": "Recipe",
                    "name": "Classic Margherita Pizza",
                    "description": "Crispy and airy dough topped with fresh basil.",
                    "recipeYield": ["2 pizzas", "2-3 servings"],
                    "prepTime": "PT20M",
                    "cookTime": "PT12M",
                    "recipeCategory": "Main Course",
                    "recipeCuisine": "Italian",
                    "recipeIngredient": [
                        "4 cups bread flour",
                        "1 tsp active dry yeast",
                        "1 1/2 cups warm water",
                        "1 tsp sea salt"
                    ],
                    "recipeInstructions": [
                        {"@type": "HowToStep", "text": "Dissolve yeast in warm water with sugar."},
                        {"@type": "HowToStep", "text": "Gradually add flour and knead for 10 minutes."},
                        {"@type": "HowToStep", "text": "Let rest for 1 hour until doubled in size."}
                    ],
                    "nutrition": {
                        "@type": "NutritionInformation",
                        "calories": "280 calories",
                        "proteinContent": "9 g"
                    }
                }
            ]
        }
        </script>
    </head>
    <body><h1>Classic Margherita Pizza</h1></body>
    </html>
    """

    let recipe = RecipeExtractor.extract(html: html, sourceURL: "https://example.com/margherita")
    #expect(recipe != nil)
    guard let recipe else { return }

    #expect(recipe.title == "Classic Margherita Pizza")
    #expect(recipe.description == "Crispy and airy dough topped with fresh basil.")
    #expect(recipe.prepTime == "20 mins")
    #expect(recipe.cookTime == "12 mins")
    #expect(recipe.cuisine == "Italian")
    #expect(recipe.ingredients.count == 4)
    #expect(recipe.instructions.count == 3)
    #expect(recipe.instructions[0].stepNumber == 1)
    #expect(recipe.instructions[0].text == "Dissolve yeast in warm water with sugar.")
    #expect(recipe.instructions[2].stepNumber == 3)
    #expect(recipe.nutrition?["calories"] == "280 calories")
}

@Test func testDurationParsing() {
    #expect(RecipeExtractor.parseDuration("PT15M") == "15 mins")
    #expect(RecipeExtractor.parseDuration("PT1H") == "1 hr")
    #expect(RecipeExtractor.parseDuration("PT1H30M") == "1 hr 30 mins")
    #expect(RecipeExtractor.parseDuration("PT2H45M") == "2 hrs 45 mins")
    #expect(RecipeExtractor.parseDuration("P1DT2H") == "1 day 2 hrs")
    #expect(RecipeExtractor.parseDuration("45 minutes") == "45 minutes")
}

@Test func testHTMLEntityUnescaping() {
    let unescaped = RecipeExtractor.unescapeHTML("Baker&#8217;s % &amp; 450&deg;F &frac12; cup")
    #expect(unescaped == "Baker's % & 450°F ½ cup")
}

@Test func testExtractJSONLDWithHowToSections() {
    let html = """
    <html><head><script type="application/ld+json">
    {
        "@context": "https://schema.org",
        "@type": "Recipe",
        "name": "Cinnamon Rolls",
        "recipeIngredient": ["3 cups flour", "1/4 cup sugar", "1 tbsp cinnamon"],
        "recipeInstructions": [
            {
                "@type": "HowToSection",
                "name": "Make the Dough",
                "itemListElement": [
                    {"@type": "HowToStep", "text": "Step 1: Combine warm milk and yeast."},
                    {"@type": "HowToStep", "text": "2. Mix in flour and knead until smooth."}
                ]
            },
            {
                "@type": "HowToSection",
                "name": "Assemble & Bake",
                "itemListElement": [
                    {"@type": "HowToStep", "name": "Roll & Cut", "text": "Roll out dough, spread cinnamon sugar, and slice into 12 rolls."}
                ]
            }
        ]
    }
    </script></head><body></body></html>
    """

    let recipe = RecipeExtractor.extract(html: html, sourceURL: "https://example.com/rolls")
    #expect(recipe != nil)
    guard let recipe else { return }

    #expect(recipe.title == "Cinnamon Rolls")
    #expect(recipe.instructions.count == 3)
    #expect(recipe.instructions[0].stepNumber == 1)
    #expect(recipe.instructions[0].section == "Make the Dough")
    #expect(recipe.instructions[0].text == "Combine warm milk and yeast.")
    #expect(recipe.instructions[1].stepNumber == 2)
    #expect(recipe.instructions[1].text == "Mix in flour and knead until smooth.")
    #expect(recipe.instructions[2].stepNumber == 3)
    #expect(recipe.instructions[2].section == "Assemble & Bake")
    #expect(recipe.instructions[2].title == "Roll & Cut")
}

@Test func testExtractMicrodataRecipe() {
    let html = """
    <html>
    <body>
        <div itemscope itemtype="https://schema.org/Recipe">
            <h1 itemprop="name">Garlic Butter Shrimp</h1>
            <p itemprop="description">Quick weeknight skillet shrimp.</p>
            <span itemprop="recipeYield">4 servings</span>
            <meta itemprop="prepTime" content="PT10M" />
            <meta itemprop="cookTime" content="PT8M" />
            <ul>
                <li itemprop="recipeIngredient">1 lb large shrimp, peeled and deveined</li>
                <li itemprop="recipeIngredient">4 tbsp unsalted butter</li>
                <li itemprop="recipeIngredient">4 cloves garlic, minced</li>
            </ul>
            <div itemprop="recipeInstructions">
                <p>1. Melt 2 tbsp butter in a large skillet over medium-high heat.</p>
                <p>2. Sear shrimp for 2 minutes per side until pink, then toss with garlic and remaining butter.</p>
            </div>
        </div>
    </body>
    </html>
    """

    let recipe = RecipeExtractor.extract(html: html, sourceURL: "https://example.com/shrimp")
    #expect(recipe != nil)
    guard let recipe else { return }

    #expect(recipe.title == "Garlic Butter Shrimp")
    #expect(recipe.yield == "4 servings")
    #expect(recipe.prepTime == "10 mins")
    #expect(recipe.cookTime == "8 mins")
    #expect(recipe.ingredients.count == 3)
    #expect(recipe.instructions.count == 2)
    #expect(recipe.instructions[0].text == "Melt 2 tbsp butter in a large skillet over medium-high heat.")
}

@Test func testExtractHeuristicsWPRM() {
    let html = """
    <html>
    <head><title>Lemon Vinaigrette - Test Kitchen</title></head>
    <body>
        <div class="wprm-recipe">
            <h2 class="wprm-recipe-name">Zesty Lemon Vinaigrette</h2>
            <div class="wprm-recipe-summary">Bright homemade salad dressing.</div>
            <ul>
                <li class="wprm-recipe-ingredient">1/4 cup fresh lemon juice</li>
                <li class="wprm-recipe-ingredient">1/2 cup extra-virgin olive oil</li>
                <li class="wprm-recipe-ingredient">1 tsp Dijon mustard</li>
            </ul>
            <ol>
                <li class="wprm-recipe-instruction-text">Whisk lemon juice and Dijon mustard together in a bowl.</li>
                <li class="wprm-recipe-instruction-text">Slowly drizzle in olive oil while whisking until emulsified.</li>
            </ol>
        </div>
    </body>
    </html>
    """

    let recipe = RecipeExtractor.extract(html: html, sourceURL: "https://example.com/vinaigrette")
    #expect(recipe != nil)
    guard let recipe else { return }

    #expect(recipe.title == "Zesty Lemon Vinaigrette")
    #expect(recipe.ingredients.count == 3)
    #expect(recipe.instructions.count == 2)
}

@Test func testExtractFromPlaintextDropsPreambleAndParsesSections() {
    let text = """
    Growing up in Vermont, we always made pancakes on snowy Sunday mornings.
    Here is my long story about why maple syrup is great and what pan I bought in 2018.

    # Fluffy Buttermilk Pancakes
    Prep Time: 10 mins
    Cook Time: 15 mins
    Total Time: 25 mins
    Servings: 4 servings

    Ingredients:
    For the Dry Mix:
    - 2 cups all-purpose flour
    - 2 tbsp granulated sugar
    - 2 tsp baking powder
    - 1/2 tsp baking soda

    For the Wet Mix:
    * 2 cups buttermilk
    * 2 large eggs
    * 1/4 cup melted butter

    Instructions:
    1. Whisk flour, sugar, baking powder, and baking soda in a large bowl.
    2. In a separate bowl, beat the buttermilk, eggs, and melted butter until combined.
    3. Fold the wet ingredients into the dry ingredients just until lumpy; do not overmix.
    4. Cook 1/3 cup scoops on a buttered griddle over medium heat until golden brown on both sides.

    Notes:
    This shouldn't be included in instructions.
    """

    let recipe = RecipeExtractor.extractFromPlaintext(text, fallbackTitle: "Fallback", sourceURL: "https://example.com/pancakes")
    #expect(recipe != nil)
    guard let recipe else { return }

    #expect(recipe.title == "Fluffy Buttermilk Pancakes")
    #expect(recipe.prepTime == "10 mins")
    #expect(recipe.cookTime == "15 mins")
    #expect(recipe.totalTime == "25 mins")
    #expect(recipe.yield == "4 servings")
    #expect(recipe.ingredients.count == 7)
    #expect(recipe.ingredients[0].section == "For the Dry Mix")
    #expect(recipe.ingredients[0].text == "2 cups all-purpose flour")
    #expect(recipe.ingredients[4].section == "For the Wet Mix")
    #expect(recipe.ingredients[4].text == "2 cups buttermilk")
    #expect(recipe.instructions.count == 4)
    #expect(recipe.instructions[0].stepNumber == 1)
    #expect(recipe.instructions[0].text == "Whisk flour, sugar, baking powder, and baking soda in a large bowl.")
    #expect(recipe.instructions[3].stepNumber == 4)
}

@Test func testNonRecipeReturnsNil() {
    let nonRecipeHTML = "<html><head><title>Go 1.24 Release Notes</title></head><body><h1>Go 1.24</h1><p>This release improves compiler performance.</p></body></html>"
    #expect(RecipeExtractor.extract(html: nonRecipeHTML) == nil)
    #expect(RecipeExtractor.extract(html: "") == nil)
    #expect(RecipeExtractor.extractFromPlaintext("Just a short note about groceries.") == nil)
    #expect(RecipeExtractor.extractFromPlaintext("") == nil)
}

@Test func testRecipeDataFormatting() {
    let populated = RecipeData(
        title: "Espresso Tonic",
        description: "Refreshing summer coffee drink.",
        yield: "1 glass",
        prepTime: "5 mins",
        ingredients: [
            RecipeIngredient(text: "150ml tonic water", section: "Base"),
            RecipeIngredient(text: "Double shot espresso", section: "Coffee"),
        ],
        instructions: [
            RecipeInstruction(stepNumber: 1, title: "Pour", text: "Fill glass with ice and pour tonic water."),
            RecipeInstruction(stepNumber: 2, text: "Slowly float the espresso on top."),
        ]
    )
    let md = populated.formattedMarkdown
    #expect(md.contains("# Espresso Tonic"))
    #expect(md.contains("## Ingredients"))
    #expect(md.contains("• 150ml tonic water"))
    #expect(md.contains("## Instructions"))
    #expect(md.contains("1. **Pour**: Fill glass with ice and pour tonic water."))

    let plain = populated.formattedIngredientsPlaintext
    #expect(plain.contains("[Base]"))
    #expect(plain.contains("• 150ml tonic water"))
    #expect(plain.contains("[Coffee]"))
}

@Test func testExtractJSONLDWithUnescapedControlCharacters() {
    // WordPress plugins occasionally emit literal unescaped newlines/tabs inside JSON-LD strings
    let html = """
    <html><head><script type="application/ld+json">
    {
        "@context": "https://schema.org",
        "@type": "Recipe",
        "name": "Rustic Sourdough
    Loaf",
        "description": "Crispy crust\tand open crumb.",
        "recipeIngredient": ["500g bread flour", "350g water", "100g starter", "10g salt"],
        "recipeInstructions": [
            {"@type": "HowToStep", "text": "Mix flour and water.
    Let autolyse for 45 minutes."},
            {"@type": "HowToStep", "text": "Add starter and salt, then perform stretch and folds."}
        ]
    }
    </script></head><body></body></html>
    """

    let recipe = RecipeExtractor.extract(html: html, sourceURL: "https://example.com/sourdough")
    #expect(recipe != nil)
    guard let recipe else { return }

    #expect(recipe.title == "Rustic Sourdough Loaf")
    #expect(recipe.description == "Crispy crust and open crumb.")
    #expect(recipe.ingredients.count == 4)
    #expect(recipe.instructions.count == 2)
    #expect(recipe.instructions[0].text == "Mix flour and water. Let autolyse for 45 minutes.")
}

@Test func testCookingWizardStepMentionsIngredient() {
    // 3-letter ingredients (egg, oil, ham, soy, rum) must match
    #expect(CookingWizardView.stepMentionsIngredient(
        stepText: "Whisk the eggs and oil together in a bowl.",
        ingredientLine: "2 large egg"
    ))
    #expect(CookingWizardView.stepMentionsIngredient(
        stepText: "Whisk the egg and olive oil together.",
        ingredientLine: "2 large eggs"
    ))
    #expect(CookingWizardView.stepMentionsIngredient(
        stepText: "Drizzle with sesame oil and soy sauce.",
        ingredientLine: "2 tbsp soy sauce"
    ))
    #expect(CookingWizardView.stepMentionsIngredient(
        stepText: "Fold in the diced ham and cheese.",
        ingredientLine: "1 cup diced ham"
    ))

    // Substring false-positives must NOT match (e.g. "our" or "pour" vs "pouring", or "ham" inside "champagne")
    #expect(!CookingWizardView.stepMentionsIngredient(
        stepText: "Slowly pour the warm water into the bowl while pouring steadily.",
        ingredientLine: "2 cups all-purpose flour"
    ))
    #expect(!CookingWizardView.stepMentionsIngredient(
        stepText: "Deglaze the pan with champagne.",
        ingredientLine: "4 oz smoked ham"
    ))

    // "salt and pepper" / seasoning pepper must match black pepper, NEVER jalapeño or bell pepper
    let step1 = "In a large bowl, add chickpeas, red onions, cherry tomatoes, jalapeños, cilantro and avocados. Stir together and set aside."
    let step2 = "For the dressing: in a small bowl, add olive oil, white wine vinegar, lime juice, minced garlic, salt and pepper. Whisk until combined."
    #expect(CookingWizardView.stepMentionsIngredient(
        stepText: step1,
        ingredientLine: "1 large jalapeño pepper (finely diced)"
    ))
    #expect(!CookingWizardView.stepMentionsIngredient(
        stepText: step1,
        ingredientLine: "1 pinch of black pepper"
    ))
    #expect(!CookingWizardView.stepMentionsIngredient(
        stepText: step2,
        ingredientLine: "1 large jalapeño pepper (finely diced)"
    ))
    #expect(!CookingWizardView.stepMentionsIngredient(
        stepText: step2,
        ingredientLine: "1 green bell pepper, diced"
    ))
    #expect(CookingWizardView.stepMentionsIngredient(
        stepText: step2,
        ingredientLine: "1 pinch of black pepper"
    ))

    // Transformative nouns ("garlic powder" vs "minced garlic") and competing qualifiers ("sesame oil" vs "olive oil")
    #expect(!CookingWizardView.stepMentionsIngredient(
        stepText: step2,
        ingredientLine: "1 teaspoon garlic powder"
    ))
    #expect(!CookingWizardView.stepMentionsIngredient(
        stepText: step2,
        ingredientLine: "1 tablespoon sesame oil"
    ))

    // Turkey Thai Lettuce Wraps: bound compound modifiers ("peanut sauce", "peanut butter"),
    // garnish role guard ("peanuts to garnish"), and sequential contiguous-cluster / gap pruning
    let thaiIngredients = [
        "1/4 cup creamy peanut butter",
        "2 tablespoons soy sauce",
        "2 tablespoons rice vinegar",
        "2 tablespoons water (see note 2)",
        "1 teaspoon sesame oil",
        "1 tablespoon lime juice",
        "1 tablespoon olive oil",
        "1 onion (finely chopped)",
        "3 cloves garlic (minced)",
        "1 tablespoon Thai red curry paste (see note 3)",
        "1 lb lean ground turkey (see note 4)",
        "1 cup carrots (shredded)",
        "romaine lettuce leaves",
        "green onions to garnish",
        "peanuts to garnish"
    ]
    let thaiSteps = [
        "Mix up peanut sauce- In a small jar or salad dressing shaker, add the peanut butter, soy sauce, rice vinegar, water, sesame oil and lime juice. Shake it up until smooth.",
        "Cook the aromatics- (1) Heat oil in a large pan and add the onions, garlic and Thai red curry paste. Stir until red curry paste is heated through and mixed in evenly with the onions (2-3 minutes).",
        "Turkey- Add the ground turkey and cook, breaking it up with a spatula, for 5-7 minutes, until no pink remains and the turkey is cooked through.",
        "Carrots & sauce- Add shredded carrots and peanut sauce to the pan and stir to combine.",
        "Serve in romaine lettuce leaves and garnish with green onions and peanuts."
    ]

    let step1Matched = CookingWizardView.matchedIngredientIndices(stepIndex: 0, steps: thaiSteps, ingredients: thaiIngredients)
    #expect(step1Matched == Set([0, 1, 2, 3, 4, 5]))
    #expect(!step1Matched.contains(14)) // "peanuts to garnish" must NOT match Step 1

    let step2Matched = CookingWizardView.matchedIngredientIndices(stepIndex: 1, steps: thaiSteps, ingredients: thaiIngredients)
    #expect(step2Matched == Set([6, 7, 8, 9]))
    #expect(!step2Matched.contains(4))  // "sesame oil" already used in Step 1
    #expect(!step2Matched.contains(13)) // "green onions to garnish" must NOT match Step 2

    let step3Matched = CookingWizardView.matchedIngredientIndices(stepIndex: 2, steps: thaiSteps, ingredients: thaiIngredients)
    #expect(step3Matched == Set([10]))

    let step4Matched = CookingWizardView.matchedIngredientIndices(stepIndex: 3, steps: thaiSteps, ingredients: thaiIngredients)
    #expect(step4Matched == Set([11]))
    #expect(!step4Matched.contains(14)) // "peanut sauce" in Step 4 must NOT match "peanuts to garnish"

    let step5Matched = CookingWizardView.matchedIngredientIndices(stepIndex: 4, steps: thaiSteps, ingredients: thaiIngredients)
    #expect(step5Matched == Set([12, 13, 14]))

    // Unclaimed interior gap & collective "the spices" bridging (Sweet Potato & Chorizo Chili)
    let chiliIngredients = [
        "2 large sweet potatoes",
        "1 whole head garlic",
        "2 poblano peppers",
        "2 tablespoons canola oil, divided",
        "1 pound uncooked Mexican chorizo",
        "1 white onion, diced small",
        "1 tablespoon cumin",
        "1 teaspoon smoked paprika",
        "1/4 teaspoon cinnamon",
        "2 cups chicken stock",
        "1 (14.5 ounce) can fire-roasted diced tomatoes",
        "1 chipotle pepper in adobo, from the can",
        "1 (15 ounce) cans black beans, drained and rinsed",
        "1 (15 ounce) can hominy, drained and rinsed"
    ]
    let chiliSteps = [
        "Preheat the oven to 400°F. Line a baking sheet with foil.",
        "Cut the papery top off of the head of garlic to expose the cloves. Place the garlic, sweet potatoes, and poblano peppers on the baking sheet and drizzle with 1 tablespoon oil.",
        "Meanwhile, heat the remaining oil in a large pot over medium-high heat. Remove the chorizo from its casing and cook until browned.",
        "Add the onion to the skillet and saute until translucent. Stir in the spices and cook for 1 minute. Pour in the chicken stock and bring to a boil.",
        "Once the sweet potatoes and peppers are cool enough to handle, use your hands to peel the skins.",
        "Add the tomatoes, chipotle pepper, black beans, and hominy to the pot and simmer."
    ]
    let chiliStep4Matched = CookingWizardView.matchedIngredientIndices(stepIndex: 3, steps: chiliSteps, ingredients: chiliIngredients)
    #expect(chiliStep4Matched == Set([5, 6, 7, 8, 9]))

    // Dutch Oven Beef Stew: parenthetical prep notes ("cut into 2-inch chunks"),
    // derivative product head noun disambiguation ("Beef Broth" != "the beef"),
    // explicit herb addition with "(to garnish)" note ("2 teaspoons Fresh Thyme Leaves (to garnish)"),
    // and sequential prior-step consumption ("Brown the beef", "return the beef to the pot", "until the beef is very tender").
    let stewIngredients = [
        "2 pounds Beef Chuck Roast (cut into 2-inch chunks, excess fat removed)",
        "1 teaspoon Kosher Salt",
        "½ teaspoon Coarsely Ground Black Pepper",
        "2 tablespoons Gluten-free All-Purpose Flour (or Whole Wheat for non-gluten)",
        "2 tablespoons Olive Oil (or avocado oil)",
        "½ Yellow Onion (Chopped Large)",
        "4 Garlic Cloves (minced)",
        "1 Large Carrot (or two small-medium, cut into 2-inch chunks)",
        "2 Yukon Gold Potatoes (diced into 2-inch pieces)",
        "2 Cups Beef Broth (see note)",
        "¼ Cup Tomato Paste",
        "1 tablespoon Worcestershire Sauce",
        "1 Bay Leaves",
        "2 teaspoons Fresh Thyme Leaves (to garnish)"
    ]
    let stewSteps = [
        "Preheat oven to 325° F.",
        "Season the 2 pounds Beef Chuck Roast (cut into chunks) on all sides with 1 teaspoon Kosher Salt and ½ teaspoon Coarsely Ground Black Pepper. Sprinkle the 2 tablespoons Gluten-free All-Purpose Flour over and toss the seasoned beef to coat it on all sides",
        "Heat the 2 tablespoons Olive Oil in a large Dutch oven (8-quart Dutch oven) over medium heat. Brown the beef in batches, on all sides, for 3-4 minutes per batch. Don't worry about cooking the beef all the way through at this stage. Transfer the browned beef to a plate and set aside.",
        "Add the ½ Yellow Onion (chopped), 4 Garlic Cloves (minced), and 1 Large Carrot (chopped) to the pot and cook for 5 minutes.",
        "Add the 2 Yukon Gold Potatoes (chopped), 2 Cups Beef Broth, ¼ Cup Tomato Paste, 1 Bay Leaves, 2 teaspoons Fresh Thyme Leaves, and 1 tablespoon Worcestershire Sauce, and use a wooden spoon to scrape the browned bits from the bottom of the pot.",
        "Bring the mixture to a simmer, stirring, and return the beef to the pot. Cover the Dutch oven, and transfer to the preheated oven",
        "Cook the stew for 2-2.5 hours, or until the beef is very tender. Remove the bay leaf. Taste the stew and season with additional salt and pepper, if necessary. Serve warm."
    ]

    #expect(CookingWizardView.matchedIngredientIndices(stepIndex: 0, steps: stewSteps, ingredients: stewIngredients) == Set([]))
    #expect(CookingWizardView.matchedIngredientIndices(stepIndex: 1, steps: stewSteps, ingredients: stewIngredients) == Set([0, 1, 2, 3]))
    #expect(CookingWizardView.matchedIngredientIndices(stepIndex: 2, steps: stewSteps, ingredients: stewIngredients) == Set([4]))
    #expect(CookingWizardView.matchedIngredientIndices(stepIndex: 3, steps: stewSteps, ingredients: stewIngredients) == Set([5, 6, 7]))
    #expect(CookingWizardView.matchedIngredientIndices(stepIndex: 4, steps: stewSteps, ingredients: stewIngredients) == Set([8, 9, 10, 11, 12, 13]))
    #expect(CookingWizardView.matchedIngredientIndices(stepIndex: 5, steps: stewSteps, ingredients: stewIngredients) == Set([]))
    #expect(CookingWizardView.matchedIngredientIndices(stepIndex: 6, steps: stewSteps, ingredients: stewIngredients) == Set([]))
}

@Test func testExtractFromPlaintextConversationalAndHeaderless() {
    let jalapenoSnippet = """
    Jalapeño Chicken Salad recipe for lunch

    A bright, spicy Jalapeño Chicken Salad makes a quick, flavorful lunch — ready in minutes with cooked chicken, fresh jalapeño, crunchy vegetables, and a creamy dressing.

    Ingredients (shopper-friendly list)
    • 2 cups cooked chicken, shredded or diced
    • 1–2 fresh jalapeños, seeded and finely chopped (adjust to taste)
    • 1/2 cup mayonnaise or Greek yogurt (for a lighter option)
    • 1/4 cup finely chopped celery or cucumber for crunch
    • 2 tablespoons chopped red onion or green onion
    • 1 tablespoon fresh lime juice or lemon juice
    • Salt and black pepper to taste
    • Optional: chopped cilantro, a pinch of cumin, diced avocado, or a drizzle of honey for balance

    Quick method
    1. Combine the cooked chicken, chopped jalapeño, celery (or cucumber), and onion in a bowl.
    2. In a small bowl mix mayonnaise (or yogurt) with lime juice, salt, and pepper. Stir in optional cilantro or spices if using.
    3. Toss dressing with the chicken mixture until evenly coated. Taste and adjust seasoning or jalapeño heat.
    4. Serve immediately on bread, in a wrap, over greens, or refrigerate for up to 3 days.

    Serving ideas
    • Classic sandwich: pile between toasted bread with lettuce and tomato.

    Tips and variations
    • Heat control: leave seeds in the jalapeño for more heat.
    """

    let recipe = RecipeExtractor.extractFromPlaintext(jalapenoSnippet, fallbackTitle: "Jalapeño Chicken Salad")
    #expect(recipe != nil)
    #expect(recipe?.ingredients.count == 8)
    #expect(recipe?.instructions.count == 4)

    let headerlessVideoNotes = """
    Easy Garlic Butter Pasta #tiktokfood #recipes
    • 2 cups cooked spaghetti
    • 3 tbsp unsalted butter
    • 4 cloves garlic, minced
    • Salt and black pepper to taste
    1. Melt the butter in a skillet over medium heat and sauté the garlic for 1 minute.
    2. Toss in the cooked spaghetti with a splash of pasta water and season with salt and pepper.
    """

    let videoRecipe = RecipeExtractor.extractFromPlaintext(headerlessVideoNotes, fallbackTitle: "Garlic Butter Pasta", sourceURL: "https://www.tiktok.com/@chef/video/123")
    #expect(videoRecipe != nil)
    #expect(videoRecipe?.ingredients.count == 4)
    #expect(videoRecipe?.instructions.count == 2)

    // Verify typo-tolerant ("avacados" -> "1-2 diced avocado") and stem-variant ("pickles" -> "1/2 cup pickled veg") matching
    let jalapenoIngs = [
        "2 cups cooked chicken, shredded or diced",
        "1–2 fresh jalapeños, seeded and finely chopped (adjust to taste)",
        "1/2 cup pickled veg, chopped (cucumber and carrots--pickle relish works too)",
        "1/2 cup mayonnaise or Greek yogurt (for a lighter option)",
        "1/4 cup finely chopped celery or cucumber for crunch",
        "3 eggs, yokes removed, chopped.",
        "1/2 tsp onion powder",
        "Salt and black pepper to taste",
        "1 tablespoon fresh lime juice or lemon juice",
        "bunch of cilantro (chopped)",
        "a pinch of cumin",
        "1-2 diced avocado",
        "a drizzle of honey for balance"
    ]
    let jalapenoSteps = [
        "Combine the cooked chicken, chopped jalapeño, pickles (and/or relish), celery (or cucumber), and eggs in a bowl. Stir in optional avacados if using.",
        "In a small bowl mix mayonnaise (or yogurt) with onion powder, salt, and pepper. Stir in optional cilantro, lime juice, honey, or spices if using.",
        "Toss dressing with the chicken mixture until evenly coated. Taste and adjust seasoning or jalapeño heat.",
        "Serve immediately on bread, in a wrap, over greens, or refrigerate for up to 3 days."
    ]
    #expect(CookingWizardView.matchedIngredientIndices(stepIndex: 0, steps: jalapenoSteps, ingredients: jalapenoIngs) == Set([0, 1, 2, 4, 5, 11]))
    #expect(CookingWizardView.matchedIngredientIndices(stepIndex: 1, steps: jalapenoSteps, ingredients: jalapenoIngs) == Set([3, 6, 7, 8, 9, 10, 12]))
}

@Test func testRecipeCookHistoryDecodingAndMarkdown() throws {
    let json = """
    {
      "title": "Roasted Carrots",
      "ingredients": [{"text": "1 lb carrots"}],
      "instructions": [{"stepNumber": 1, "text": "Roast at 425F for 25 minutes."}],
      "cookHistory": [
        {
          "cookedAt": "2026-04-12T19:00:00Z",
          "rating": 5,
          "note": "Added honey glaze"
        }
      ]
    }
    """
    let data = Data(json.utf8)
    let recipe = try JSONDecoder().decode(RecipeData.self, from: data)
    #expect(recipe.cookHistory.count == 1)
    #expect(recipe.cookHistory[0].rating == 5)
    #expect(recipe.cookHistory[0].note == "Added honey glaze")
    #expect(recipe.cookHistory[0].formattedStars == "★★★★★")
    #expect(recipe.formattedMarkdown.contains("## Cook Log (1)"))
    #expect(recipe.formattedMarkdown.contains("Added honey glaze"))
}

@Test func testRecipePDFGenerationSingleAndMultiPage() throws {
    let recipe = RecipeData(
        title: "Braised Short Ribs",
        description: "Rich, fork-tender beef short ribs braised in red wine and aromatics.",
        author: "Chef Test",
        sourceURL: "https://example.com/short-ribs",
        yield: "4 servings",
        prepTime: "25 mins",
        cookTime: "2 hrs 30 mins",
        totalTime: "2 hrs 55 mins",
        category: "Dinner",
        cuisine: "French",
        ingredients: [
            RecipeIngredient(text: "4 lbs bone-in beef short ribs", section: "Main"),
            RecipeIngredient(text: "2 tbsp kosher salt", section: "Main"),
            RecipeIngredient(text: "2 cups dry red wine", section: "Braising Liquid"),
            RecipeIngredient(text: "3 cups beef stock", section: "Braising Liquid")
        ],
        instructions: [
            RecipeInstruction(stepNumber: 1, title: "Sear", text: "Brown the seasoned short ribs on all sides in a Dutch oven."),
            RecipeInstruction(stepNumber: 2, title: "Braise", text: "Add red wine and beef stock, cover, and braise at 325°F for 2.5 hours.")
        ],
        nutrition: ["calories": "680 kcal", "protein": "48g"],
        cookHistory: [
            RecipeCookEntry(cookedAt: "2026-11-08T18:30:00Z", rating: 5, note: "Served over creamy polenta.")
        ]
    )

    let pdfData = RecipePDFGenerator.renderPDF(for: recipe)
    #expect(pdfData != nil)
    guard let pdfData else { return }
    // Verify PDF magic header "%PDF-"
    let prefix = String(data: pdfData.prefix(5), encoding: .ascii)
    #expect(prefix == "%PDF-")
    #expect(pdfData.count > 1000)

    let stagedURL = RecipePDFGenerator.stagePDFFile(for: recipe)
    #expect(stagedURL != nil)
    #expect(stagedURL?.lastPathComponent == "braised-short-ribs.pdf")
}

@Test func testExtractFromPlaintextDoesNotMisparseParentheticalCanIngredientsAsSteps() {
    let cookbookOCR = """
    ARKHAN THE CRUEL'S FLAME-ROASTED HALFLING CHILI
    SERVES 4 TO 6
    In a small bowl, mix together the cocoa powder, chili powder, cinnamon, oregano, cumin, allspice, cloves, cayenne, ½ teaspoon salt, and ½ teaspoon pepper. Set aside.
    In a blender or food processor, purée half the kidney beans with about ½ cup of the broth until smooth and set aside.
    INGREDIENTS
    ½ cup unsweetened cocoa powder
    1½ tablespoons chili powder
    1 (15-ounce) can dark red kidney beans, undrained and rinsed
    2 cups low-sodium chicken broth, divided
    4 slices bacon
    1 yellow onion, finely chopped
    5 garlic cloves, finely chopped
    1 (15-ounce) can tomato pureé
    2 tablespoons thick and rich tomato paste
    2 pounds ground turkey (or ground beef, pork, venison)
    1 tablespoon cider vinegar
    """

    let extracted = RecipeExtractor.extractFromPlaintext(cookbookOCR, fallbackTitle: "Arkhan Chili")
    #expect(extracted == nil)
}



