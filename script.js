const card = document.querySelector(".hover-card");

const handleMove = (event) => {
  const bounds = card.getBoundingClientRect();
  const centerX = bounds.left + bounds.width / 2;
  const centerY = bounds.top + bounds.height / 2;
  const x = event.clientX - centerX;
  const y = event.clientY - centerY;
  const rotateX = (y / bounds.height) * -10;
  const rotateY = (x / bounds.width) * 10;

  card.style.transform = `rotateX(${rotateX}deg) rotateY(${rotateY}deg)`;
};

const resetCard = () => {
  card.style.transform = "rotateX(0deg) rotateY(0deg)";
};

card.addEventListener("pointermove", (event) => {
  card.classList.add("is-hovered");
  handleMove(event);
});

card.addEventListener("pointerenter", () => {
  card.classList.add("is-hovered");
});

card.addEventListener("pointerleave", () => {
  card.classList.remove("is-hovered");
  resetCard();
});

card.addEventListener("pointerdown", () => card.classList.add("is-hovered"));
card.addEventListener("pointerup", () => card.classList.add("is-hovered"));
