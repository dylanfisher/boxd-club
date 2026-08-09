# The one decorative line on pages that would otherwise be bare: under the
# sign-in form, and under each error heading.
#
# Replaces the old lib/taglines.rb and lib/lost_quotes.rb, which were puns
# ("Say hello to my little link"). These are real film lines, attributed.
#
# Each context is a mood, not a keyword match. A line earns its place by
# reading like it was written about the page it lands on — a 404 gets lines
# about absence, a 403 gets lines about being turned away. If a line would
# work equally well anywhere, it works nowhere; cut it.
#
# Quotes are kept to a single short line and carry film + year, so the page
# credits what it's borrowing.

module Quotes
  Quote = Struct.new(:text, :film, :year) do
    def to_s = text
    def credit = "#{film}, #{year}"
  end

  # Signing in: doors, thresholds, passwords, greetings, names.
  ENTRY = [
    ["Speak, friend, and enter.", "The Lord of the Rings: The Fellowship of the Ring", 2001],
    ["Shall we play a game?", "WarGames", 1983],
    ["Here's looking at you, kid.", "Casablanca", 1942],
    ["Round up the usual suspects.", "Casablanca", 1942],
    ["We'll always have Paris.", "Casablanca", 1942],
    ["Play it, Sam.", "Casablanca", 1942],
    ["You had me at hello.", "Jerry Maguire", 1996],
    ["Show me the money!", "Jerry Maguire", 1996],
    ["Open the pod bay doors, HAL.", "2001: A Space Odyssey", 1968],
    ["Come with me if you want to live.", "Terminator 2: Judgment Day", 1991],
    ["I'll be back.", "The Terminator", 1984],
    ["Welcome to the party, pal!", "Die Hard", 1988],
    ["Bond. James Bond.", "Dr. No", 1962],
    ["My name is Inigo Montoya.", "The Princess Bride", 1987],
    ["As you wish.", "The Princess Bride", 1987],
    ["Have fun storming the castle!", "The Princess Bride", 1987],
    ["May the Force be with you.", "Star Wars", 1977],
    ["Help me, Obi-Wan Kenobi. You're my only hope.", "Star Wars", 1977],
    ["Do or do not. There is no try.", "The Empire Strikes Back", 1980],
    ["Never tell me the odds.", "The Empire Strikes Back", 1980],
    ["E.T. phone home.", "E.T. the Extra-Terrestrial", 1982],
    ["Follow the white rabbit.", "The Matrix", 1999],
    ["Wake up, Neo.", "The Matrix", 1999],
    ["I'm Batman.", "Batman", 1989],
    ["Nobody puts Baby in a corner.", "Dirty Dancing", 1987],
    ["Roads? Where we're going, we don't need roads.", "Back to the Future", 1985],
    ["Yo, Adrian!", "Rocky", 1976],
    ["Good morning, Vietnam!", "Good Morning, Vietnam", 1987],
    ["I'm ready for my close-up.", "Sunset Boulevard", 1950],
    ["I'm going to make him an offer he can't refuse.", "The Godfather", 1972],
    ["Leave the gun. Take the cannoli.", "The Godfather", 1972],
    ["Keep your friends close, but your enemies closer.", "The Godfather Part II", 1974],
    ["Carpe diem. Seize the day.", "Dead Poets Society", 1989],
    ["To infinity and beyond!", "Toy Story", 1995],
    ["Just keep swimming.", "Finding Nemo", 2003],
    ["Adventure is out there!", "Up", 2009],
    ["Welcome to Jurassic Park.", "Jurassic Park", 1993],
    ["Hold onto your butts.", "Jurassic Park", 1993],
    ["I feel the need — the need for speed.", "Top Gun", 1986],
    ["You're a wizard, Harry.", "Harry Potter and the Sorcerer's Stone", 2001],
    ["I am Groot.", "Guardians of the Galaxy", 2014],
    ["I am Iron Man.", "Iron Man", 2008],
    ["With great power comes great responsibility.", "Spider-Man", 2002],
    ["Wakanda forever!", "Black Panther", 2018],
    ["There's no place like home.", "The Wizard of Oz", 1939],
    ["Follow the yellow brick road.", "The Wizard of Oz", 1939],
    ["Are you talking to me?", "Taxi Driver", 1976],
    ["Say hello to my little friend!", "Scarface", 1983],
    ["Hello, gorgeous.", "Funny Girl", 1968],
    ["I'll have what she's having.", "When Harry Met Sally...", 1989],
    ["Snap out of it!", "Moonstruck", 1987],
    ["I'm the king of the world!", "Titanic", 1997],
    ["Made it, Ma! Top of the world!", "White Heat", 1949],
    ["Stella! Hey, Stella!", "A Streetcar Named Desire", 1951],
    ["Nobody's perfect.", "Some Like It Hot", 1959],
    ["Go ahead, make my day.", "Sudden Impact", 1983],
    ["The Dude abides.", "The Big Lebowski", 1998],
    ["Welcome to Fight Club.", "Fight Club", 1999],
    ["Choose life.", "Trainspotting", 1996],
    ["Are you not entertained?", "Gladiator", 2000],
    ["This is Sparta!", "300", 2006],
    ["Why so serious?", "The Dark Knight", 2008],
    ["Here's Johnny!", "The Shining", 1980],
    ["They're here.", "Poltergeist", 1982],
    ["It's alive!", "Frankenstein", 1931],
    ["What is your quest?", "Monty Python and the Holy Grail", 1975],
    ["Klaatu barada nikto.", "The Day the Earth Stood Still", 1951],
    ["Good evening.", "Dracula", 1931],
    ["Wax on, wax off.", "The Karate Kid", 1984],
    ["There's no crying in baseball!", "A League of Their Own", 1992],
    ["My mama always said life was like a box of chocolates.", "Forrest Gump", 1994],
    ["Second star to the right, and straight on till morning.", "Peter Pan", 1953],
    ["Curiouser and curiouser.", "Alice in Wonderland", 1951],
    ["Toto, I've a feeling we're not in Kansas anymore.", "The Wizard of Oz", 1939]
  ].freeze

  # 404: absence, disappearance, empty rooms, wrong turns.
  MISSING = [
    ["These aren't the droids you're looking for.", "Star Wars", 1977],
    ["And like that... he's gone.", "The Usual Suspects", 1995],
    ["The greatest trick the Devil ever pulled was convincing the world he didn't exist.", "The Usual Suspects", 1995],
    ["There is no spoon.", "The Matrix", 1999],
    ["Rosebud.", "Citizen Kane", 1941],
    ["All those moments will be lost in time, like tears in rain.", "Blade Runner", 1982],
    ["Forget it, Jake. It's Chinatown.", "Chinatown", 1974],
    ["Nothing is written.", "Lawrence of Arabia", 1962],
    ["I see dead people.", "The Sixth Sense", 1999],
    ["Vanished. Like a fart in the wind.", "The Shawshank Redemption", 1994],
    ["Toto, I've a feeling we're not in Kansas anymore.", "The Wizard of Oz", 1939],
    ["Pay no attention to that man behind the curtain.", "The Wizard of Oz", 1939],
    ["There's no place like home.", "The Wizard of Oz", 1939],
    ["It's gone, Mr. Frodo.", "The Lord of the Rings: The Return of the King", 2003],
    ["I've got a bad feeling about this.", "Star Wars", 1977],
    ["There is another.", "The Empire Strikes Back", 1980],
    ["The horror... the horror.", "Apocalypse Now", 1979],
    ["Don't panic.", "The Hitchhiker's Guide to the Galaxy", 2005],
    ["So long, and thanks for all the fish.", "The Hitchhiker's Guide to the Galaxy", 2005],
    ["I'm not dead yet!", "Monty Python and the Holy Grail", 1975],
    ["Bring out your dead!", "Monty Python and the Holy Grail", 1975],
    ["Run away!", "Monty Python and the Holy Grail", 1975],
    ["He's not the Messiah, he's a very naughty boy!", "Monty Python's Life of Brian", 1979],
    ["The call is coming from inside the house.", "When a Stranger Calls", 1979],
    ["We're all mad here.", "Alice in Wonderland", 1951],
    ["Reality is often disappointing.", "Avengers: Infinity War", 2018],
    ["Nothing ever ends.", "Watchmen", 2009],
    ["I want to be alone.", "Grand Hotel", 1932],
    ["Frankly, my dear, I don't give a damn.", "Gone with the Wind", 1939],
    ["After all, tomorrow is another day.", "Gone with the Wind", 1939],
    ["I coulda been a contender.", "On the Waterfront", 1954],
    ["What we've got here is failure to communicate.", "Cool Hand Luke", 1967],
    ["Hope is a good thing, maybe the best of things.", "The Shawshank Redemption", 1994],
    ["Get busy living, or get busy dying.", "The Shawshank Redemption", 1994],
    ["My precious.", "The Lord of the Rings: The Two Towers", 2002],
    ["Time to die.", "Blade Runner", 1982],
    ["It's just a flesh wound.", "Monty Python and the Holy Grail", 1975],
    ["Nobody knows anything.", "Chinatown", 1974],
    ["I'm walkin' here!", "Midnight Cowboy", 1969],
    ["Life moves pretty fast.", "Ferris Bueller's Day Off", 1986],
    ["That rug really tied the room together.", "The Big Lebowski", 1998],
    ["Nobody's perfect.", "Some Like It Hot", 1959],
    ["The stuff that dreams are made of.", "The Maltese Falcon", 1941],
    ["I'm sorry, Dave. I'm afraid I can't do that.", "2001: A Space Odyssey", 1968],
    ["Wake up, Neo.", "The Matrix", 1999]
  ].freeze

  # 403: being turned away, wrong door, not on the list.
  FORBIDDEN = [
    ["You shall not pass!", "The Lord of the Rings: The Fellowship of the Ring", 2001],
    ["You didn't say the magic word!", "Jurassic Park", 1993],
    ["Only the penitent man shall pass.", "Indiana Jones and the Last Crusade", 1989],
    ["He chose... poorly.", "Indiana Jones and the Last Crusade", 1989],
    ["I'm sorry, Dave. I'm afraid I can't do that.", "2001: A Space Odyssey", 1968],
    ["Nobody gets in to see the Wizard. Not nobody, not no how!", "The Wizard of Oz", 1939],
    ["You can't handle the truth!", "A Few Good Men", 1992],
    ["None shall pass.", "Monty Python and the Holy Grail", 1975],
    ["You can't sit with us.", "Mean Girls", 2004],
    ["Nobody tosses a Dwarf!", "The Lord of the Rings: The Two Towers", 2002],
    ["Fly, you fools!", "The Lord of the Rings: The Fellowship of the Ring", 2001],
    ["These aren't the droids you're looking for.", "Star Wars", 1977],
    ["It's a trap!", "Return of the Jedi", 1983],
    ["Say hello to my little friend!", "Scarface", 1983],
    ["Frankly, my dear, I don't give a damn.", "Gone with the Wind", 1939],
    ["Go ahead, make my day.", "Sudden Impact", 1983],
    ["The first rule of Fight Club is: you do not talk about Fight Club.", "Fight Club", 1999],
    ["Nobody puts Baby in a corner.", "Dirty Dancing", 1987],
    ["I'm walkin' here!", "Midnight Cowboy", 1969],
    ["Why so serious?", "The Dark Knight", 2008],
    ["This is Sparta!", "300", 2006],
    ["Wrong door.", "The Godfather", 1972],
    ["What is your quest?", "Monty Python and the Holy Grail", 1975],
    ["Are you talking to me?", "Taxi Driver", 1976],
    ["You're gonna need a bigger boat.", "Jaws", 1975]
  ].freeze

  # Expired links and stale forms: time running out, arriving too late.
  EXPIRED = [
    ["This tape will self-destruct in five seconds.", "Mission: Impossible", 1996],
    ["Time to die.", "Blade Runner", 1982],
    ["All those moments will be lost in time, like tears in rain.", "Blade Runner", 1982],
    ["Life moves pretty fast.", "Ferris Bueller's Day Off", 1986],
    ["Great Scott!", "Back to the Future", 1985],
    ["Roads? Where we're going, we don't need roads.", "Back to the Future", 1985],
    ["After all, tomorrow is another day.", "Gone with the Wind", 1939],
    ["I'll be back.", "The Terminator", 1984],
    ["Hasta la vista, baby.", "Terminator 2: Judgment Day", 1991],
    ["Nothing gold can stay.", "The Outsiders", 1983],
    ["And like that... he's gone.", "The Usual Suspects", 1995],
    ["Nothing is written.", "Lawrence of Arabia", 1962],
    ["We'll always have Paris.", "Casablanca", 1942],
    ["Play it, Sam.", "Casablanca", 1942],
    ["Get busy living, or get busy dying.", "The Shawshank Redemption", 1994],
    ["Carpe diem. Seize the day.", "Dead Poets Society", 1989],
    ["Just keep swimming.", "Finding Nemo", 2003],
    ["Nobody's perfect.", "Some Like It Hot", 1959],
    ["The horror... the horror.", "Apocalypse Now", 1979],
    ["Rosebud.", "Citizen Kane", 1941],
    ["I've got a bad feeling about this.", "Star Wars", 1977],
    ["Time is the fire in which we burn.", "Star Trek: Generations", 1994],
    ["Don't panic.", "The Hitchhiker's Guide to the Galaxy", 2005],
    ["It's gone, Mr. Frodo.", "The Lord of the Rings: The Return of the King", 2003],
    ["Second star to the right, and straight on till morning.", "Peter Pan", 1953]
  ].freeze

  # 500: something is on fire and we would rather you didn't watch.
  BROKEN = [
    ["Houston, we have a problem.", "Apollo 13", 1995],
    ["Failure is not an option.", "Apollo 13", 1995],
    ["What we've got here is failure to communicate.", "Cool Hand Luke", 1967],
    ["I'm sorry, Dave. I'm afraid I can't do that.", "2001: A Space Odyssey", 1968],
    ["I've got a bad feeling about this.", "Star Wars", 1977],
    ["Hold onto your butts.", "Jurassic Park", 1993],
    ["Life finds a way.", "Jurassic Park", 1993],
    ["Well, that escalated quickly.", "Anchorman: The Legend of Ron Burgundy", 2004],
    ["It's alive!", "Frankenstein", 1931],
    ["You're gonna need a bigger boat.", "Jaws", 1975],
    ["Don't panic.", "The Hitchhiker's Guide to the Galaxy", 2005],
    ["It's just a flesh wound.", "Monty Python and the Holy Grail", 1975],
    ["Run away!", "Monty Python and the Holy Grail", 1975],
    ["The horror... the horror.", "Apocalypse Now", 1979],
    ["Nobody's perfect.", "Some Like It Hot", 1959],
    ["I'm not dead yet!", "Monty Python and the Holy Grail", 1975],
    ["Snap out of it!", "Moonstruck", 1987],
    ["Why so serious?", "The Dark Knight", 2008],
    ["Great Scott!", "Back to the Future", 1985],
    ["Toto, I've a feeling we're not in Kansas anymore.", "The Wizard of Oz", 1939],
    ["Forget it, Jake. It's Chinatown.", "Chinatown", 1974],
    ["Reality is often disappointing.", "Avengers: Infinity War", 2018],
    ["I'll be back.", "The Terminator", 1984],
    ["Just keep swimming.", "Finding Nemo", 2003],
    ["We'll fix it in post.", "Living in Oblivion", 1995]
  ].freeze

  BY_CONTEXT = {
    entry: ENTRY,
    missing: MISSING,
    forbidden: FORBIDDEN,
    expired: EXPIRED,
    broken: BROKEN
  }.freeze

  module_function

  # An unknown context would otherwise blow up a page that is, by definition,
  # already having a bad time — so fall back rather than raise.
  def random(context)
    rows = BY_CONTEXT[context] || MISSING
    Quote.new(*rows.sample)
  end
end
