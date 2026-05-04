#!/usr/bin/env python3
"""
Filter NPI trace CSV output based on keyword patterns.

Usage:
    python filter_trace.py <input.csv> <output.csv> <keyword1> [keyword2 ...]

Example:
    python filter_trace.py trace.csv filtered.csv "Memory" "RegCombo"

The script will copy rows containing ANY of the specified keywords to the output file.
"""

import sys
import csv

def filter_csv(input_file, output_file, keywords):
    """
    Filter CSV rows that contain any of the specified keywords.

    Args:
        input_file: Path to input CSV file
        output_file: Path to output CSV file
        keywords: List of keyword strings to match
    """
    matched_count = 0
    total_count = 0

    with open(input_file, 'r', encoding='utf-8') as infile, \
         open(output_file, 'w', encoding='utf-8', newline='') as outfile:

        reader = csv.reader(infile)
        writer = csv.writer(outfile)

        # Copy header
        header = next(reader)
        writer.writerow(header)

        # Process data rows
        for row in reader:
            total_count += 1
            # Join all fields in the row to search
            row_text = ','.join(row)

            # Check if any keyword is in the row
            if any(keyword in row_text for keyword in keywords):
                writer.writerow(row)
                matched_count += 1

    print("Filtered {} out of {} rows".format(matched_count, total_count))
    print("Output written to: {}".format(output_file))

def main():
    if len(sys.argv) < 4:
        print("Usage: python filter_trace.py <input.csv> <output.csv> <keyword1> [keyword2 ...]")
        print("\nExample:")
        print("  python filter_trace.py trace.csv filtered.csv Memory RegCombo")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]
    keywords = sys.argv[3:]

    print("Input file: {}".format(input_file))
    print("Output file: {}".format(output_file))
    print("Keywords: {}".format(keywords))
    print()

    try:
        filter_csv(input_file, output_file, keywords)
    except FileNotFoundError:
        print("Error: Input file '{}' not found".format(input_file))
        sys.exit(1)
    except Exception as e:
        print("Error: {}".format(e))
        sys.exit(1)

if __name__ == "__main__":
    main()
