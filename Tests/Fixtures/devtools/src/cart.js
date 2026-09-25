function cartTotal(items) {
  var total = 0;
  for (var i = 0; i < items.length; i++) {
    total += items[i].price * items[i].qty;
  }
  return total;
}
function checkout(items) {
  var sum = cartTotal(items);
  console.trace("checkout total", sum);
  return sum;
}
window.checkout = checkout;
