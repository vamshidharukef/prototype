//
// For guidance on how to create routes see:
// https://prototype-kit.service.gov.uk/docs/create-routes
//

const govukPrototypeKit = require('govuk-prototype-kit')
const router = govukPrototypeKit.requests.setupRouter()

// Add your routes here
router.get('/1-0/dashboard/inputter', function (req, res) {
  // The data object is automatically passed to the template
  res.render('1-0/dashboard/inputter')
})

module.exports = router