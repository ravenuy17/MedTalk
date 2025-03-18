import sys
import cv2
import pytesseract
import spacy
import numpy as np
import pyttsx3  # For text-to-speech
import tensorflow as tf
from tensorflow.keras.models import Sequential
from tensorflow.keras.layers import Dense, Embedding, GlobalAveragePooling1D

# Additional libraries for CSV loading and fuzzy matching
import pandas as pd
from rapidfuzz import process

# -------------------------------
# Part 1: Computer Vision & OCR
# -------------------------------
def capture_image_from_webcam():
    """
    Captures an image from the default webcam, displays the live video feed,
    and waits for the user to press 'c' to capture or 'q' to quit.
    Returns the path to the saved image (e.g., "temp.jpg").
    """
    cap = cv2.VideoCapture(0)  # 0 = default camera; change if you have multiple
    if not cap.isOpened():
        raise IOError("Cannot open webcam")

    print("Press 'c' to capture an image, or 'q' to quit.")

    saved_image_path = "temp.jpg"

    while True:
        ret, frame = cap.read()
        if not ret:
            print("Failed to read from webcam.")
            break

        # Show the live camera feed
        cv2.imshow("Webcam - Press 'c' to Capture, 'q' to Quit", frame)
        key = cv2.waitKey(1) & 0xFF

        if key == ord('c'):
            # Save the frame to disk
            cv2.imwrite(saved_image_path, frame)
            print(f"Image captured and saved to {saved_image_path}")
            break
        elif key == ord('q'):
            print("Quitting without capturing image.")
            saved_image_path = None
            break

    cap.release()
    cv2.destroyAllWindows()
    return saved_image_path

def preprocess_image(image_path):
    """
    Reads the image, converts it to grayscale, and applies thresholding.
    This helps Tesseract OCR get a cleaner input.
    """
    image = cv2.imread(image_path)
    if image is None:
        raise ValueError(f"Image not found at {image_path}!")
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    # Use Otsu's thresholding to binarize the image
    _, thresh = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY | cv2.THRESH_OTSU)
    return thresh

def extract_text_from_image(image):
    """
    Uses pytesseract to perform OCR on the preprocessed image.
    """
    custom_config = r'--oem 3 --psm 6'
    text = pytesseract.image_to_string(image, config=custom_config)
    return text

# -------------------------------
# Part 2: Natural Language Processing
# -------------------------------
def extract_info_with_nlp(text):
    """
    Uses spaCy to process the extracted text and return identified entities.
    You can later add more rules to extract specific information such as
    medicine names, expiry dates, batch numbers, etc.
    """
    nlp = spacy.load("en_core_web_sm")
    doc = nlp(text)
    entities = [(ent.text, ent.label_) for ent in doc.ents]
    return entities

# -------------------------------
# Part 2.5: Medication Matching with CSV
# -------------------------------
def load_medication_list(csv_path):
    """
    Loads a CSV file containing medication names.
    Assumes there's a column named 'Molecule'.
    """
    df = pd.read_csv(csv_path)
    # Adjust column name to whatever matches your CSV
    medication_list = df['Molecule'].tolist()
    # Convert to lowercase for more consistent matching
    medication_list = [med.lower() for med in medication_list]
    return medication_list

def match_medications_fuzzy(text, medication_list, threshold=85):
    """
    Splits the extracted text into tokens and uses fuzzy matching against
    the medication list. Returns a set of recognized medication names.
    
    - `threshold=85` can be adjusted for stricter or looser matching.
    """
    tokens = text.lower().split()
    recognized_meds = set()

    for token in tokens:
        result = process.extractOne(token, medication_list)
        if result is not None:
            match, score, _ = result
            if score >= threshold:
                recognized_meds.add(match)
    return recognized_meds

# -------------------------------
# Part 3: TensorFlow Model & TFLite Conversion
# -------------------------------
def create_text_classification_model(vocab_size, embedding_dim, max_length, num_classes):
    """
    Creates a simple text classification model.
    In a production scenario, you would train this model on labeled data.
    """
    model = Sequential([
        Embedding(vocab_size, embedding_dim, input_length=max_length),
        GlobalAveragePooling1D(),
        Dense(24, activation='relu'),
        Dense(num_classes, activation='softmax')
    ])
    
    model.compile(loss='sparse_categorical_crossentropy',
                  optimizer='adam',
                  metrics=['accuracy'])
    return model

def convert_model_to_tflite(model, tflite_model_path):
    """
    Converts the given TensorFlow/Keras model to a TensorFlow Lite model.
    """
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    # (Optional) Enable optimization for a smaller and faster model:
    # converter.optimizations = [tf.lite.Optimize.DEFAULT]
    tflite_model = converter.convert()
    with open(tflite_model_path, "wb") as f:
        f.write(tflite_model)
    print(f"Converted model saved to {tflite_model_path}")

# -------------------------------
# Part 4: Text-to-Speech Helper
# -------------------------------
def speak_text(text):
    """
    Uses pyttsx3 for offline text-to-speech.
    Adjust voice properties as needed.
    """
    engine = pyttsx3.init()
    # Optionally adjust speech rate, volume, voice, etc.
    engine.setProperty('rate', 150)    # Speed percent (can go faster/slower)
    engine.setProperty('volume', 1.0)  # Volume 0.0 to 1.0
    engine.say(text)
    engine.runAndWait()

# -------------------------------
# Main Pipeline Function
# -------------------------------
def main():
    # 1) Capture an image from the user's webcam
    image_path = capture_image_from_webcam()
    if not image_path:
        print("No image captured. Exiting.")
        return

    # 2) Preprocess and run OCR
    processed_image = preprocess_image(image_path)
    extracted_text = extract_text_from_image(processed_image)
    print("=== Extracted Text ===")
    print(extracted_text)

    # 3) Process text using NLP (Named Entities)
    entities = extract_info_with_nlp(extracted_text)
    print("\n=== Extracted Entities (via spaCy NER) ===")
    for ent_text, ent_label in entities:
        print(f"{ent_text} ({ent_label})")

    # 4) Match text against medication CSV (fuzzy)
    medication_list_csv = r"D:\Capstone_NU\flutter_application_1\DOH_Medication_List.csv"
    medication_list = load_medication_list(medication_list_csv)
    
    recognized_meds = match_medications_fuzzy(extracted_text, medication_list, threshold=85)
    print("\n=== Recognized Medications (Fuzzy Matching) ===")
    if recognized_meds:
        # Read each recognized medication out loud
        for med in recognized_meds:
            print(med)
            speak_text(f"The medication recognized is {med}")
    else:
        print("No recognized medications.")
        speak_text("No recognized medications found.")

    # 5) (Optional) Run text through a ML model (example)
    vocab_size = 1000      # Example vocabulary size
    embedding_dim = 16     # Dimension for word embeddings
    max_length = 100       # Maximum token sequence length
    num_classes = 3        # Assume we have three target classes
    
    model = create_text_classification_model(vocab_size, embedding_dim, max_length, num_classes)
    
    # For demonstration, we simulate tokenized input with random integers.
    dummy_input = np.random.randint(0, vocab_size, size=(1, max_length))
    prediction = model.predict(dummy_input)
    print("\n=== Dummy Classification Prediction ===")
    print(prediction)
    
    # 6) Convert the model to TensorFlow Lite (if needed)
    tflite_model_path = "text_classification_model.tflite"
    convert_model_to_tflite(model, tflite_model_path)

# -------------------------------
# Entry Point
# -------------------------------
if __name__ == "__main__":
    main()
