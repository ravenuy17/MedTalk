class StringUtils {
  static String toTitleCase(String input) {
    if (input.isEmpty) return input;
    List<String> words = input.split(' ');
    return words
        .map((word) => word.isNotEmpty
            ? word[0].toUpperCase() + word.substring(1).toLowerCase()
            : '')
        .join(' ');
  }
}
